#!/bin/bash
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

set -Eeo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT

function log_message() {
    echo -e "${1}"
    if [ -z "$IS_AUTOSCALE_RUN" ]; then
        echo -e "${1}" >> "${FEEDSIM_ROOT}/LOGs/run.sh.log"
    fi
}

SCRIPT_NAME="$(basename "$0")"

# Assumes run.sh is copied to the benchmark directory
#  ${BENCHPRESS_ROOT}/feedsim/run.sh

# Function for BC
BC_MAX_FN='define max (a, b) { if (a >= b) return (a); return (b); }'
BC_MIN_FN='define min (a, b) { if (a <= b) return (a); return (b); }'

# Constants
FEEDSIM_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)
FEEDSIM_ROOT_SRC="${FEEDSIM_ROOT}/src"


# RANKING_THREADS_DEFAULT: PageRank computation threads
# EVENTBASE_THREADS_DEFAULT: IO TimeSleep threads
# SRV_THREADS_DEFAULT: Pointer chasing threads
# SRV_IO_THREADS_DEFAULT: Compression threads
# DRIVER_THREADS: Driver Node threads
# THRIFT_THREADS_DEFAULT: LeafNode Threads - Serialization, Deserialization

# Thrift threads: scale with logical CPUs till 216. Having more than that
# will risk running out of memory and getting killed
IS_SMT_ON="$(cat /sys/devices/system/cpu/smt/active)"
THRIFT_THREADS_DEFAULT="$(echo "${BC_MIN_FN}; min($(nproc), 216)" | bc)"
EVENTBASE_THREADS_DEFAULT=4  # 4 should suffice. Tune up if threads are saturated.
SRV_THREADS_DEFAULT=8        # 8 should also suffice for most purposes
if [[ "$IS_SMT_ON" = 1 ]]; then
  RANKING_THREADS_DEFAULT="$(( $(nproc) * 7/20))"  # 7/20 is 0.35 cpu factor
  SRV_IO_THREADS_DEFAULT="$(echo "${BC_MIN_FN}; min($(nproc) * 7/20, 55)" | bc)" # 0.35 cpu factor, max 55
  DRIVER_THREADS="$(echo "scale=2; $(nproc) / 5.0 + 0.5 " | bc )"  # Driver threads, rounds nearest.
  DRIVER_THREADS="${DRIVER_THREADS%.*}"  # Truncate decimal fraction.
  DRIVER_THREADS="$(echo "${BC_MAX_FN}; max(${DRIVER_THREADS:-0}, 4)" | bc )" # At least 4 threads.
else
  RANKING_THREADS_DEFAULT="$(( $(nproc) * 15/20))"  # 15/20 is 0.75 cpu factor
  SRV_IO_THREADS_DEFAULT="$(echo "${BC_MIN_FN}; min($(nproc) * 11/20, 55)" | bc)" # 0.55 cpu factor, max 55
  DRIVER_THREADS="$(echo "scale=2; $(nproc) / 4.0 + 0.5 " | bc )"  # Driver threads, rounds nearest.
  DRIVER_THREADS="${DRIVER_THREADS%.*}"  # Truncate decimal fraction.
  DRIVER_THREADS="$(echo "${BC_MAX_FN}; max(${DRIVER_THREADS:-0}, 4)" | bc )" # At least 4 threads.
fi


show_help() {
cat <<EOF
Usage: ${0##*/} [OPTION]...

     -h Display this help and exit
     -t Number of threads to use for thrift serving. Large dataset kept per thread. Default: $THRIFT_THREADS_DEFAULT
     -c Number of threads to use for fanout ranking work. Heavy CPU work. Default: $RANKING_THREADS_DEFAULT
     -s Number of threads to use for task-based serialization cpu work. Default: $SRV_IO_THREADS_DEFAULT
     -a When searching for the optimal QPS, automatically adjust the number of client driver threads by
         min(requested_qps / 4, $(nproc) / 5) in each iteration (experimental feature).
     -q Number of QPS to request. If this is present, feedsim will run a fixed-QPS experiment instead of searching
         for a QPS that meets latency target. If multiple comma-separated values are specified, a fixed-QPS experiment
         will be run for each QPS value.
     -d Duration of each load testing experiment, in seconds. Default: 300
     -w Warmup time in seconds before starting experiments. Default: 120
     -i I-cache iterations for the benchmark workload. Default: 1600000
     -p Port to use by the LeafNodeRank server and the load drivers. Default: 11222
     -o Result output file name. Default: "feedsim_results.txt"
     --inst-num Instance number for multi-instance runs. Used for per-instance logging.
     --is-autoscale Set to non-zero for autoscale/multi-instance runs. Controls per-instance log file naming.
EOF
}

cleanup() {
  # remove trap handler
  trap - SIGINT SIGTERM ERR EXIT
  # Stop monitoring process if running
  if [ -n "$MONITOR_PID" ]; then
    kill -SIGTERM $MONITOR_PID 2>/dev/null || true
  fi
  # Check if child process has already been started
  if [ -n "$LEAF_PID" ]; then
    kill -SIGKILL $LEAF_PID || true # Ignore exit status code of kill
  fi
}

msg() {
  echo >&2 -e "${1-}"
}

die() {
  local msg=$1
  local code=${2-1} # default exit status 1
  msg "$msg"
  exit "$code"
}


# Background monitoring function for LeafNode
monitor_leaf_stats() {
    local monitor_port=$1
    local log_file=$2    
    while true; do
        sleep 5
        timestamp=$(date +"%Y-%m-%d %H:%M:%S")
        if stats_data=$(curl -s --max-time 2 "http://0.0.0.0:${monitor_port}/child_stats" 2>/dev/null); then
            if echo "$stats_data" | jq empty 2>/dev/null; then
                extracted=$(echo "$stats_data" | jq -c '.stats["5"]["0"]' 2>/dev/null)
                if [ "$extracted" != "null" ] && [ -n "$extracted" ]; then
                    echo "${timestamp} ${extracted}" >> "$log_file"
                fi
            fi
        fi
        
    done
}



main() {
    local thrift_threads
    thrift_threads="$THRIFT_THREADS_DEFAULT"

    local ranking_cpu_threads
    ranking_cpu_threads="$RANKING_THREADS_DEFAULT"

    local srv_io_threads
    srv_io_threads="$SRV_IO_THREADS_DEFAULT"

    local auto_driver_threads
    auto_driver_threads="1"

    local fixed_qps
    fixed_qps=""

    local experiment_duration
    experiment_duration="300"

    local warmup_time
    warmup_time="120"

    local port
    port="11222"

    local icache_iterations
    icache_iterations="1600000"

    local inst_num
    inst_num="0"

    local result_filename
    result_filename="${FEEDSIM_ROOT}/result/feedsim_results.txt"

    if [ -z "$IS_AUTOSCALE_RUN" ]; then
        rm -rf "${FEEDSIM_ROOT}/LOGs"
        mkdir -p "${FEEDSIM_ROOT}/LOGs"
        rm -rf "${FEEDSIM_ROOT}/result"
        mkdir -p "${FEEDSIM_ROOT}/result"
    fi

    log_message "${SCRIPT_NAME}: DCPERF_PERF_RECORD=${DCPERF_PERF_RECORD} \n"

    log_message "IS_SMT_ON=${IS_SMT_ON}"
    log_message "NCPU=$(nproc)"
    log_message "THRIFT_THREADS_DEFAULT=${THRIFT_THREADS_DEFAULT}"
    log_message "RANKING_THREADS_DEFAULT=${RANKING_THREADS_DEFAULT}"
    log_message "SRV_IO_THREADS_DEFAULT=${SRV_IO_THREADS_DEFAULT}"
    log_message "EVENTBASE_THREADS_DEFAULT=${EVENTBASE_THREADS_DEFAULT}"
    log_message "SRV_THREADS_DEFAULT=${SRV_THREADS_DEFAULT}"
    log_message "DRIVER_THREADS=${DRIVER_THREADS} \n"

    while [ $# -ne 0 ]; do
        case $1 in
            -t)
                thrift_threads="$2"
                ;;
            -c)
                ranking_cpu_threads="$2"
                ;;
            -s)
                srv_io_threads="$2"
                ;;
            -a)
                auto_driver_threads="1"
                ;;
            -q)
                fixed_qps="$2"
                ;;
            -d)
                experiment_duration="$2"
                ;;
            -w)
                warmup_time="$2"
                ;;
            -p)
                port="$2"
                ;;
            -o)
                result_filename="$2"
                ;;
            -i)
                icache_iterations="$2"
                ;;
            --inst-num)
                inst_num="$2"
                ;;
            -h|--help)
                show_help >&2
                exit 1
                ;;
            *)  # end of input
                echo "Unsupported arg '$1'" 1>&2
                break
        esac

        case $1 in
            -t|-c|-s|-d|-p|-q|-o|-w|-i|--inst-num)
                if [ -z "$2" ]; then
                    echo "Invalid option: '$1' requires an argument" 1>&2
                    exit 1
                fi
                shift   # Additional shift for the argument
                ;;
        esac
        shift # pop the previously read argument
    done

    set -u  # Enable unbound variables check from here onwards

    # Bring up services
    # 1. Leaf Node
    # 2. Parent
    # 3. Start Load Driver

    cd "${FEEDSIM_ROOT_SRC}"

    # Starting leaf node service

    # cpu_threads: PageRank computation threads
    # io_threads: IO TimeSleep threads
    # srv_threads: Pointer chasing threads
    # srv_io_threads: Compression threads
    # threads i.e., thrift_threads: LeafNode Threads - Serialization, Deserialization
    monitor_port=$((port-1000))

    log_message "leaf_node_threads=${thrift_threads}"
    log_message "ranking_cpu_threads=${ranking_cpu_threads}"
    log_message "srv_io_threads=${srv_io_threads}"
    log_message "leafnode_monitor_port-${inst_num}=${monitor_port}"
    log_message "inst_num=${inst_num} \n"

    leaf_node_cmd="MALLOC_CONF=narenas:20,dirty_decay_ms:5000 build/workloads/ranking/LeafNodeRank \
        --port='$port' \
        --monitor_port='$monitor_port' \
        --graph_scale=21 \
        --graph_subset=2000000 \
        --threads='$thrift_threads' \
        --cpu_threads='$ranking_cpu_threads' \
        --timekeeper_threads=2 \
        --io_threads='$EVENTBASE_THREADS_DEFAULT' \
        --srv_threads='$SRV_THREADS_DEFAULT' \
        --srv_io_threads='$srv_io_threads' \
        --num_objects=2000 \
        --graph_max_iters=1 \
        --noaffinity \
        --min_icache_iterations='$icache_iterations' \
        > '${FEEDSIM_ROOT}/LOGs/LeafNodeRank-${inst_num}.log' 2>&1 &"
    
    log_message "Starting LeafNodeRank with command: ${leaf_node_cmd} \n"
    eval "$leaf_node_cmd"

    LEAF_PID=$!

    # FIXME(cltorres)
    # Remove sleep, expose an endpoint or print a message to notify service is ready
    sleep 90

    # Start background monitoring of LeafNode stats
    MONITOR_LOG_FILE="${FEEDSIM_ROOT}/LOGs/LeafNodeStatsMonitor-${inst_num}.log"
    monitor_leaf_stats "$monitor_port" "$MONITOR_LOG_FILE" &
    MONITOR_PID=$!
    echo "Starting LeafNode Stats Monitoring, logging to: $MONITOR_LOG_FILE (PID: $MONITOR_PID)"

    # FIXME(cltorres)
    # Skip ParentNode for now, and talk directly to LeafNode
    # ParentNode acts as a simple proxy, and does not influence
    # workload too much. Unfortunately, disabling for now
    # it's not robust at start up, and causes too many failures
    # when trying to create sockets for listening.

    # Start DriverNode
    client_monitor_port="$((monitor_port-1000))"
    log_message "drivernode_monitor_port-${inst_num}=${client_monitor_port} \n"

    if [ -z "$fixed_qps" ] && [ "$auto_driver_threads" != "1" ]; then

        search_qps_cmd="scripts/search_qps.sh -w 15 -f 300 -s 95p:500 -o '${result_filename}' --inst-num '$inst_num' --is-autoscale '${IS_AUTOSCALE_RUN:-0}' -- \
            build/workloads/ranking/DriverNodeRank \
                --server '0.0.0.0:$port' \
                --monitor_port '$client_monitor_port' \
                --threads='${DRIVER_THREADS}' \
                --connections=4"
        
        log_message "Running search_qps: \n ${search_qps_cmd} \n"
        eval "$search_qps_cmd"
        log_message "Completed search_qps"

    elif [ -z "$fixed_qps" ] && [ "$auto_driver_threads" = "1" ]; then
        search_qps_cmd="scripts/search_qps.sh -a -w 15 -f 300 -s 95p:500 -o '${result_filename}' --inst-num '$inst_num' --is-autoscale '${IS_AUTOSCALE_RUN:-0}' -- \
            build/workloads/ranking/DriverNodeRank \
                --monitor_port '$client_monitor_port' \
                --server '0.0.0.0:$port'"
        
        log_message "Running search_qps: \n ${search_qps_cmd} \n"
        eval "$search_qps_cmd"
        log_message "Completed search_qps"
    else
        if [ "$auto_driver_threads" = "1" ]; then
            # Use auto driver threads mode
            search_qps_cmd="scripts/search_qps.sh -a -s 95p -t '$experiment_duration' \
               -m '$warmup_time' \
               -q '$fixed_qps' \
               -o '${result_filename}' \
               --inst-num '$inst_num' \
               --is-autoscale '${IS_AUTOSCALE_RUN:-0}' \
               -- build/workloads/ranking/DriverNodeRank \
                    --server '0.0.0.0:$port' \
                    --monitor_port '$client_monitor_port'"
        else
            # Use fixed DRIVER_THREADS
            num_connections=4
            num_workers=$DRIVER_THREADS
            search_qps_cmd="scripts/search_qps.sh -s 95p -t '$experiment_duration' \
               -m '$warmup_time' \
               -q '$fixed_qps' \
               -o '${result_filename}' \
               --inst-num '$inst_num' \
               --is-autoscale '${IS_AUTOSCALE_RUN:-0}' \
               -- build/workloads/ranking/DriverNodeRank \
                    --server '0.0.0.0:$port' \
                    --monitor_port '$client_monitor_port' \
                    --threads='${num_workers}' \
                    --connections='${num_connections}'"
        fi
        
        log_message "Running fixed_qps_exp: \n ${search_qps_cmd} \n"
        eval "$search_qps_cmd"
        log_message "Completed fixed_qps_exp"
    fi

    sleep 5 # wait for queue to drain
    kill -SIGINT $LEAF_PID || true > /dev/null # SIGINT so exits cleanly
}

main "$@"

# vim: tabstop=4 shiftwidth=4 expandtab
