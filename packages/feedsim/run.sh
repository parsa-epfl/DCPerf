#!/bin/bash
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

set -Eeo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT

function log_message() {
    local prefix=""
    if [ -n "${IS_AUTOSCALE_RUN:-}" ] && [ "${IS_AUTOSCALE_RUN}" -gt 1 ] && [ -n "${INST_NUM:-}" ]; then
        prefix="[${INST_NUM}] "
    fi
    echo -e "${prefix}${1}"
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

# Delete and recreate LOGs directory
rm -rf "${FEEDSIM_ROOT}/LOGs"
mkdir -p "${FEEDSIM_ROOT}/LOGs"
rm -rf "${FEEDSIM_ROOT}/result"
mkdir -p "${FEEDSIM_ROOT}/result"


show_help() {
cat <<EOF
Usage: ${0##*/} [OPTION]...

Configuration is primarily done through environment variables:
    THRIFT_THREADS       - Number of threads for thrift serving (required)
    RANKING_THREADS      - Number of threads for fanout ranking work (required)
    SRV_IO_THREADS       - Number of threads for task-based serialization (required)
    EVENTBASE_THREADS    - Number of IO TimeSleep threads (default: 4)
    SRV_THREADS          - Number of pointer chasing threads (default: 8)
    DRIVER_THREADS       - Number of driver threads (optional, uses auto mode if not set)
    WARMUP_DURATION      - Warmup duration in seconds (default: 120)
    FIXED_QPS_DURATION   - Duration of fixed-QPS experiments in seconds (default: 300)
    FIXED_QPS            - Fixed QPS value(s) (optional, comma-separated)
    SERVER_NODE_CPUS     - CPU list for server (LeafNodeRank) affinity via taskset (optional)
    CLIENT_NODE_CPUS     - CPU list for client (DriverNodeRank) affinity via taskset (optional)

Command line options:
     -h Display this help and exit
     -t Number of threads to use for thrift serving (overrides THRIFT_THREADS)
     -c Number of threads to use for fanout ranking work (overrides RANKING_THREADS)
     -s Number of threads to use for task-based serialization cpu work (overrides SRV_IO_THREADS)
     -q Number of QPS to request (overrides FIXED_QPS). If this is present, feedsim will run a fixed-QPS experiment instead of searching
         for a QPS that meets latency target. If multiple comma-separated values are specified, a fixed-QPS experiment
         will be run for each QPS value.
     -d Duration of each load testing experiment, in seconds (overrides FIXED_QPS_DURATION)
     -w Warmup time in seconds before starting experiments (overrides WARMUP_DURATION)
     -i I-cache iterations for the benchmark workload. Default: 1600000
     -p Port to use by the LeafNodeRank server and the load drivers. Default: 11222
     -o Result output file name. Default: "feedsim_results.txt"
     --inst-num Instance number for multi-instance runs. Used for per-instance logging.
     --is-autoscale Set to non-zero for autoscale/multi-instance runs. Controls per-instance log file naming.
     --no-auto-driver-threads Disable automatic driver thread adjustment. Uses fixed calculation based on allocated CPUs.
         By default, driver threads are automatically adjusted per QPS iteration (auto mode).
     --num-driver-threads Number of driver threads to use for load generation. This overrides auto mode.
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
    MONITOR_PID=""
    LEAF_PID=""
    
    # Initialize from environment variables
    local thrift_threads
    thrift_threads="${THRIFT_THREADS:-}"

    local ranking_cpu_threads
    ranking_cpu_threads="${RANKING_THREADS:-}"

    local srv_io_threads
    srv_io_threads="${SRV_IO_THREADS:-}"

    local eventbase_threads
    eventbase_threads="${EVENTBASE_THREADS:-4}"

    local srv_threads
    srv_threads="${SRV_THREADS:-8}"

    local auto_driver_threads
    auto_driver_threads="1"

    local driver_threads
    driver_threads="${DRIVER_THREADS:-}"

    local fixed_qps
    fixed_qps="${FIXED_QPS:-}"

    local experiment_duration
    experiment_duration="${FIXED_QPS_DURATION:-300}"

    local warmup_time
    warmup_time="${WARMUP_DURATION:-120}"

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
            --no-auto-driver-threads)
                auto_driver_threads="0"
                ;;
            --num-driver-threads)
                driver_threads="$2"
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
            -t|-c|-s|-d|-p|-q|-o|-w|-i|--inst-num|--num-driver-threads)
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

    # Set global INST_NUM for use in log_message
    INST_NUM="$inst_num"

    # Validate required environment variables
    if [ -z "$thrift_threads" ]; then
        die "THRIFT_THREADS environment variable must be set"
    fi
    if [ -z "$ranking_cpu_threads" ]; then
        die "RANKING_THREADS environment variable must be set"
    fi
    if [ -z "$srv_io_threads" ]; then
        die "SRV_IO_THREADS environment variable must be set"
    fi

    # Log configuration
    log_message "${SCRIPT_NAME}: DCPERF_PERF_RECORD=${DCPERF_PERF_RECORD:-0} \n"

    log_message "SYSTEM_TOTAL_CPUS=$(nproc)"
    log_message "THRIFT_THREADS=${thrift_threads}"
    log_message "RANKING_THREADS=${ranking_cpu_threads}"
    log_message "SRV_IO_THREADS=${srv_io_threads}"
    log_message "EVENTBASE_THREADS=${eventbase_threads}"
    log_message "SRV_THREADS=${srv_threads} \n"

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

    # Prepare taskset prefix for server if SERVER_NODE_CPUS is set
    local server_taskset_prefix=""
    if [ -n "${SERVER_NODE_CPUS:-}" ]; then
        server_taskset_prefix="taskset -c $SERVER_NODE_CPUS"
    fi

    log_message "leaf_node_threads=${thrift_threads}"
    log_message "ranking_cpu_threads=${ranking_cpu_threads}"
    log_message "srv_io_threads=${srv_io_threads}"
    log_message "leafnode_monitor_port-${inst_num}=${monitor_port}"
    log_message "inst_num=${inst_num} \n"

    leaf_node_cmd="$server_taskset_prefix env MALLOC_CONF=narenas:20,dirty_decay_ms:5000 build/workloads/ranking/LeafNodeRank \
        --port='$port' \
        --monitor_port='$monitor_port' \
        --graph_scale=21 \
        --graph_subset=2000000 \
        --threads='$thrift_threads' \
        --cpu_threads='$ranking_cpu_threads' \
        --timekeeper_threads=2 \
        --io_threads='$eventbase_threads' \
        --srv_threads='$srv_threads' \
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
    log_message "Starting LeafNode Stats Monitoring, logging to: $MONITOR_LOG_FILE (PID: $MONITOR_PID)"

    # FIXME(cltorres)
    # Skip ParentNode for now, and talk directly to LeafNode
    # ParentNode acts as a simple proxy, and does not influence
    # workload too much. Unfortunately, disabling for now
    # it's not robust at start up, and causes too many failures
    # when trying to create sockets for listening.

    # Start DriverNode
    client_monitor_port="$((monitor_port-1000))"
    log_message "drivernode_monitor_port-${inst_num}=${client_monitor_port} \n"

    # Prepare taskset prefix for client if CLIENT_NODE_CPUS is set
    local client_taskset_prefix=""
    if [ -n "${CLIENT_NODE_CPUS:-}" ]; then
        client_taskset_prefix="taskset -c $CLIENT_NODE_CPUS"
    fi

    # Determine thread configuration for search_qps.sh
    local driver_thread_args=""
    if [ -n "$driver_threads" ]; then
        # Explicit driver threads specified with --num-driver-threads, passed as -n to search_qps.sh
        driver_thread_args="-n ${driver_threads}"
    elif [ "$auto_driver_threads" = "1" ]; then
        # Auto mode enabled (default or via old -a flag if it existed)
        driver_thread_args="-a"
    fi
    # If auto_driver_threads=0, pass nothing (search_qps.sh will use default calculation)

    # Build and execute search_qps command
    if [ -z "$fixed_qps" ]; then
        # QPS search mode
        search_qps_cmd="$client_taskset_prefix env DCPERF_PERF_RECORD=${DCPERF_PERF_RECORD:-0} scripts/search_qps.sh ${driver_thread_args} -w 15 -f 300 \
            -s 95p:500 \
            -o '${result_filename}' \
            --inst-num '$inst_num' \
            --is-autoscale '${IS_AUTOSCALE_RUN:-0}' -- \
            build/workloads/ranking/DriverNodeRank \
                --server '0.0.0.0:$port' \
                --monitor_port '$client_monitor_port'"
        
        log_message "Running search_qps: \n ${search_qps_cmd} \n"
        eval "$search_qps_cmd"
        log_message "Completed search_qps"
    else
        # Fixed QPS mode
        search_qps_cmd="$client_taskset_prefix env DCPERF_PERF_RECORD=${DCPERF_PERF_RECORD:-0} scripts/search_qps.sh ${driver_thread_args} \
           -s 95p:500 -t '$experiment_duration' \
           -m '$warmup_time' \
           -q '$fixed_qps' \
           -o '${result_filename}' \
           --inst-num '$inst_num' \
           --is-autoscale '${IS_AUTOSCALE_RUN:-0}' \
           -- build/workloads/ranking/DriverNodeRank \
                --server '0.0.0.0:$port' \
                --monitor_port '$client_monitor_port'"
        
        log_message "Running fixed_qps_exp: \n ${search_qps_cmd} \n"
        eval "$search_qps_cmd"
        log_message "Completed fixed_qps_exp"
    fi

    sleep 5 # wait for queue to drain
    kill -SIGINT $LEAF_PID || true > /dev/null # SIGINT so exits cleanly
}

main "$@"

# vim: tabstop=4 shiftwidth=4 expandtab
