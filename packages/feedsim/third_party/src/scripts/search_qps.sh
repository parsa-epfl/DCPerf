#!/bin/bash
#
# Copyright 2015 Google Inc. All Rights Reserved.
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# Licensed under the Apache License, Version 2.0 (the "License");3261891
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

FEEDSIM_ROOT=$(realpath "$(dirname "${BASH_SOURCE[0]}")/../..")

# Trap handler for cleanup
trap cleanup SIGINT SIGTERM ERR EXIT

cleanup() {
  
    # Remove trap handler to prevent recursion
    trap - SIGINT SIGTERM ERR EXIT
    
    # Stop monitoring process if running
    if [ -n "$MONITOR_PID" ]; then
        kill -SIGTERM $MONITOR_PID 2>/dev/null || true
        wait $MONITOR_PID 2>/dev/null || true
    fi
    
    # Stop loadtest process if running
    if [ -n "$LOADTEST_PID" ]; then
        kill -SIGINT $LOADTEST_PID 2>/dev/null || true
        wait $LOADTEST_PID 2>/dev/null || true
    fi
    
    # Stop perf record if running
    if [ -n "$PERF_PID" ]; then
        kill -SIGINT $PERF_PID 2>/dev/null || true
        wait $PERF_PID 2>/dev/null || true
    fi    
}

function log_message() {
    local prefix=""
    if [ -n "${IS_AUTOSCALE_RUN}" ] && [ "${IS_AUTOSCALE_RUN}" -gt 1 ] && [ -n "${inst_num}" ]; then
        prefix="[${inst_num}] "
    fi
    echo -e "${prefix}${1}"
    if [ -n "${IS_AUTOSCALE_RUN}" ] && [ "${IS_AUTOSCALE_RUN}" != "0" ]; then
        echo -e "${1}" >> "${FEEDSIM_ROOT}/LOGs/search_qps.sh.${inst_num}.log"
    else
        echo -e "${1}" >> "${FEEDSIM_ROOT}/LOGs/search_qps.sh.log"
    fi
}


# Calculate driver threads based on specified value, auto mode, or default calculation
# calculate_driver_threads resultvar req_qps
# Returns thread count via pass-by-reference
# Uses global max_driver_threads variable
function calculate_driver_threads() {
  local __resultvar=$1
  local req_qps="$2"
  local num_threads=""
  
  # Priority: specified (-n) > auto (-a) > default (calculated)
  if [ -n "$specified_driver_threads" ]; then
      # Use specified thread count from -n argument
      num_threads="$specified_driver_threads"
  else
      if [ "$auto_driver_threads" = "1" ]; then
          # Auto mode: adjust threads based on requested QPS
          local num_connections=4
          if [ -n "$req_qps" ]; then
              num_threads=$(echo "$req_qps / $num_connections" | bc)
              # Clamp between 1 and max_driver_threads
              if [ "$num_threads" -lt 1 ]; then
                  num_threads=1
              elif [ "$num_threads" -gt "$max_driver_threads" ]; then
                  num_threads="$max_driver_threads"
              fi
          else
              num_threads=${max_driver_threads}
          fi
      else
          # Default mode: use max_driver_threads
          num_threads=${max_driver_threads}
      fi
  fi
  
  eval $__resultvar="'$num_threads'"
}


# Scale up max_driver_threads if bottleneck detected
# scale_up_max_driver_threads resultvar current_threads current_max requested_qps measured_qps measured_latency
function scale_up_max_driver_threads() {
  local __resultvar=$1
  local current_threads="$2"
  local current_max="$3"
  local requested_qps="$4"
  local measured_qps="$5"
  local measured_latency="$6"
  local result_value="$current_max"
  
  # Only scale if we're at the ceiling
  if [ "$current_threads" -lt "$MAX_DRIVER_THREADS_DEFAULT" ]; then
      log_message "scale_up_max_driver_threads: Not at ceiling ($current_threads < $MAX_DRIVER_THREADS_DEFAULT), no scaling"
      eval $__resultvar="'$result_value'"
      return
  fi
  
  # Determine QPS scaling factor
  local qps_scaling_factor="1.0"
  local qps_ratio=$(echo "scale=4; $measured_qps / $requested_qps" | bc)
  
  if [ "$(echo "$qps_ratio < 0.7" | bc)" = "1" ]; then
      qps_scaling_factor="1.15"
      # log_message "scale_up_max_driver_threads: QPS ratio ${qps_ratio} < 0.7, qps_scaling_factor: 1.15"
  elif [ "$(echo "$qps_ratio < 0.8" | bc)" = "1" ]; then
      qps_scaling_factor="1.10"
      # log_message "scale_up_max_driver_threads: QPS ratio ${qps_ratio} < 0.8, qps_scaling_factor: 1.10"
  elif [ "$(echo "$qps_ratio < 0.9" | bc)" = "1" ]; then
      qps_scaling_factor="1.05"
      # log_message "scale_up_max_driver_threads: QPS ratio ${qps_ratio} < 0.9, qps_scaling_factor: 1.05"
  elif [ "$(echo "$qps_ratio < 0.95" | bc)" = "1" ]; then
      qps_scaling_factor="1.02"
      # log_message "scale_up_max_driver_threads: QPS ratio ${qps_ratio} < 0.95, qps_scaling_factor: 1.02"
  else
      log_message "scale_up_max_driver_threads: QPS ratio ${qps_ratio} >= 0.95, no scaling needed"
      eval $__resultvar="'$result_value'"
      return
  fi
  
  # Determine latency scaling factor (use default 500ms if no target set)
  local latency_scaling_factor="1.0"
  local effective_latency_target="${latency_target:-500}"
  
  local latency_gap=$(echo "scale=4; $effective_latency_target - $measured_latency" | bc)
  local threshold_15=$(echo "scale=4; $effective_latency_target * 0.15" | bc)
  local threshold_10=$(echo "scale=4; $effective_latency_target * 0.10" | bc)
  local threshold_05=$(echo "scale=4; $effective_latency_target * 0.05" | bc)
  local threshold_03=$(echo "scale=4; $effective_latency_target * 0.03" | bc)
  
  if [ "$(echo "$latency_gap > $threshold_15" | bc)" = "1" ]; then
      latency_scaling_factor="1.1"
      # log_message "scale_up_max_driver_threads: Latency gap ${latency_gap} > 15% of target ($effective_latency_target), latency_scaling_factor: 1.1"
  elif [ "$(echo "$latency_gap > $threshold_10" | bc)" = "1" ]; then
      latency_scaling_factor="1.05"
      # log_message "scale_up_max_driver_threads: Latency gap ${latency_gap} > 10% of target ($effective_latency_target), latency_scaling_factor: 1.05"
  elif [ "$(echo "$latency_gap > $threshold_05" | bc)" = "1" ]; then
      latency_scaling_factor="1.02"
      # log_message "scale_up_max_driver_threads: Latency gap ${latency_gap} > 5% of target ($effective_latency_target), latency_scaling_factor: 1.02"
  elif [ "$(echo "$latency_gap > $threshold_03" | bc)" = "1" ]; then
      latency_scaling_factor="1.01"
      # log_message "scale_up_max_driver_threads: Latency gap ${latency_gap} > 3% of target ($effective_latency_target), latency_scaling_factor: 1.01"
  else
      log_message "scale_up_max_driver_threads: Insufficient latency headroom (gap: $latency_gap <= 3% of $effective_latency_target), no latency-based scaling"
      eval $__resultvar="'$result_value'"
      return
  fi
  
  # Calculate combined scaling factor
  local scale_factor=$(echo "scale=4; $qps_scaling_factor * $latency_scaling_factor" | bc)
    
  # Scale up the ceiling
  result_value=$(echo "scale=0; $current_max * $scale_factor / 1" | bc)
  # log_message "scale_up_max_driver_threads: Scaling max_driver_threads from $current_max to $result_value"
  
  eval $__resultvar="'$result_value'"
}


# Run loadtest with adaptive scaling of driver threads
# run_loadtest_with_adaptive_scaling output_qps output_latency target_qps
function run_loadtest_with_adaptive_scaling() {
  local __output_qps=$1
  local __output_latency=$2
  local target_qps="$3"
  local max_retries=5
  local retry_count=0
  local current_max_driver_threads="$max_driver_threads"
  local result_qps=""
  local result_latency=""
  
  while [ $retry_count -lt $max_retries ]; do
      # Calculate driver threads with current ceiling
      local driver_threads=""
      max_driver_threads="$current_max_driver_threads"
      calculate_driver_threads driver_threads "$target_qps"
      
      # Run the loadtest
      result_qps=""
      result_latency=""
      run_loadtest result_qps result_latency "$driver_threads" "$target_qps"
      
      # Only attempt adaptive scaling if auto mode is enabled
      if [ "$auto_driver_threads" != "1" ]; then
          break
      fi
      
      # Attempt to scale up (scale_up function will validate if scaling is needed)
      local new_max=""
      scale_up_max_driver_threads new_max "$driver_threads" "$current_max_driver_threads" "$target_qps" "$result_qps" "$result_latency"
      
      # Check if scaling actually happened
      if [ "$new_max" = "$current_max_driver_threads" ]; then
          break
      fi
      
      log_message "run_loadtest_with_adaptive_scaling: Iteration $((retry_count+1)): Scaling max from $current_max_driver_threads to $new_max"
      current_max_driver_threads="$new_max"
      retry_count=$((retry_count + 1))
  done
  
  if [ $retry_count -ge $max_retries ]; then
      log_message "run_loadtest_with_adaptive_scaling: Reached max retries ($max_retries), stopping"
  fi
  
  # Update global max_driver_threads if it changed
  max_driver_threads="$current_max_driver_threads"
  
  # Return final results
  eval $__output_qps="'$result_qps'"
  eval $__output_latency="'$result_latency'"
}



function tuning_reduce_qps () {
  local output_var=${1}
  local measured_latency_local=${2}
  local latency_target_local=${3}
  local cur_qps_local=${4}

  # calculate % gap to measured_latency
  local latency_gap=$(echo "scale=5; (($measured_latency_local - $latency_target_local) / $latency_target_local)" | bc)
  # latency gap bigger than 100%
  local latency_gap_huge_condition=$(echo "$latency_gap > 1" | bc)
  # latency gap in (50%,100%) range
  local latency_gap_big_condition=$(echo "$latency_gap <= 1 && $latency_gap > 0.5" | bc)
  # latency gap in (5%, 50%)
  local latency_gap_managable=$(echo "$latency_gap <= 0.5 && $latency_gap >= 0.05" | bc)

  if [ $latency_gap_huge_condition -eq 1 ] ; then
    # huge latency gap, just reduce gps by half.
    cur_qps_local=$(echo "scale=5; $cur_qps_local*0.5" | bc)
  elif [ $latency_gap_big_condition -eq 1 ] ; then
    # big latency gap, just reduce gps by half.
    cur_qps_local=$(echo "scale=5; $cur_qps_local*0.5" | bc)
  elif [ $latency_gap_managable -eq 1 ] ; then
    # latency gap in <5%, 50%), reduce qps by that gap divided by 5.
    cur_qps_local=$(echo "scale=5; $cur_qps_local * (1 - ($latency_gap / 5))" | bc)
  else
    cur_qps_local=$(echo "scale=5; $cur_qps_local * 99 / 100" | bc)
  fi

  log_message "Measured latency: $measured_latency_local"
  log_message "Latency target: $latency_target_local"
  log_message "Latency gap: $latency_gap"
  log_message "Latency gap huge condition: $latency_gap_huge_condition"
  log_message "Latency gap big condition: $latency_gap_big_condition"
  log_message "Latency gap managable condition: $latency_gap_managable"
  log_message "New QPS: $cur_qps_local"
  
  eval "$output_var='$cur_qps_local'"
}






# Usage info
show_help() {
cat << EOF
Usage: ${0##*/} [-h] [-t experiment time] [-f final experiment time] [-w wait time] [-s scan arguments] -- driver command
Finds the maximum QPS that satisfies a latency target.
Algorithm to find QPS for latency target adapted from Jacob Leverich\'s
mutilate (EuroSys \'14) [https://github.com/leverich/mutilate]

  -h          display this help and exit
  -t          amount of time to run each experiment in seconds. Default: 30 seconds
  -f          amount of time to run final experiments in seconds. Default: 90 seconds
  -w          amount of time to wait before starting next experiment. Default: 5 seconds
  -m          amount of time to warmup in seconds. Default: same as the value of -t
  -s          metric:target (in msec). Example: 99p:5.01. Allowable metrics
        are avg, 50p, 90p, 95p, 99p, 99.9p
  -q          number of qps to use. If this option is present, the program will execute
        a fixed-qps experiment instead of searching. Optional
  -n          specified number of driver threads to use. Overrides -a and default number of threads.
  -a          let ${0##*/} automatically adjust the number of driver's worker threads by
        appending '--threads=T --connections=4' to the driver command during load
        tests. T will be the lesser of requested_qps / 4 or allocated_cpus / 5.
  -o          output filename to record samples as csv. Optional
  --inst-num  Instance number for multi-instance runs. Used for per-instance logging.
  --is-autoscale Set to non-zero for autoscale/multi-instance runs. Controls per-instance log file naming.
  --num-logical-cpus Number of logical CPUs allocated to this instance. Used to calculate
        default driver threads when neither -n nor -a is specified. Default: $(nproc)
EOF
}




# Background monitoring function for DriverNode
monitor_driver_stats() {
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




# Run the load test and pull results
# run_loadtest output_qps output_latency num_threads [target qps]
run_loadtest() {
  local __output_qps=$1
  local __output_latency=$2
  local num_threads=$3
  local qps_arg=""
  local threads_arg="--threads=$num_threads --connections=4"

  # check for optional QPS argument
  if [ $# -eq 4 ]; then
    qps_arg="--qps=$4"
  fi

  log_message "run_loadtest: $run_load_type: command: $command $threads_arg $qps_arg"
  log_message "run_loadtest: $run_load_type: COMMAND STARTED" 

  for r in $(seq 1 $load_test_retries); do
    if [ -n "${IS_AUTOSCALE_RUN}" ] && [ "${IS_AUTOSCALE_RUN}" != "0" ]; then
        local drivernode_log_file="${FEEDSIM_ROOT}/LOGs/DriverNode-${inst_num}-${run_load_type}.log"
    else
        local drivernode_log_file="${FEEDSIM_ROOT}/LOGs/DriverNode-${run_load_type}.log"
    fi
    $command $threads_arg $qps_arg &>"$drivernode_log_file" &
    LOADTEST_PID=$!
    sleep 7
    ps -p $LOADTEST_PID -o pid= > /dev/null && break
    log_message "run_loadtest: Retrying $r of 3 to start load test..."
  done

  # Extract monitor port from command and start monitoring
  local monitor_port=""
  if echo "$command $threads_arg $qps_arg" | grep -q -- "--monitor_port"; then
    monitor_port=$(echo "$command $threads_arg $qps_arg" | grep -oP '(?<=--monitor_port[= ])[0-9]+' | head -1)
    if [ -n "$monitor_port" ] && [ "$monitor_port" -gt 0 ] 2>/dev/null; then
      if [ -n "${IS_AUTOSCALE_RUN}" ] && [ "${IS_AUTOSCALE_RUN}" != "0" ]; then
          local monitor_log_file="${FEEDSIM_ROOT}/LOGs/DriverNodeStatsMonitor-${inst_num}-${run_load_type}.log"
      else
          local monitor_log_file="${FEEDSIM_ROOT}/LOGs/DriverNodeStatsMonitor-${run_load_type}.log"
      fi      
      monitor_driver_stats "$monitor_port" "$monitor_log_file" &
      MONITOR_PID=$!
      log_message "DriverNode Stats Monitoring, logging to: $monitor_log_file (PID: $MONITOR_PID)"
    fi
  fi


  # wait for time
  log_message "run_loadtest: $run_load_type: SLEEP STARTED: ${experiment_time}s"
  sleep $experiment_time
  log_message "run_loadtest: $run_load_type: SLEEP ENDED"


  # Stop monitoring process if running
  if [ -n "$MONITOR_PID" ]; then
    kill -SIGTERM $MONITOR_PID 2>/dev/null || true
    wait $MONITOR_PID 2>/dev/null || true
    MONITOR_PID=""
  fi


  # send SIGINT to the command
  kill -SIGINT $LOADTEST_PID
  log_message "run_loadtest: $run_load_type: COMMAND ENDED" 

  # wait for results to show up and queries to drain
  sleep $wait_time

  # check file for QPS
  if grep -q "#: [0-9]\+.\([0-9]\+\)\? QPS" $drivernode_log_file; then
    local qps=$(cat $drivernode_log_file | grep QPS | awk '{print $2}')
  else
    log_message "Could not find QPS in loadtest output ${drivernode_log_file}" >&2
    exit 1;
  fi

  if grep -q "$latency_type: [0-9]\+.\([0-9]\+\)\? ms" $drivernode_log_file; then
    local latency=$(cat $drivernode_log_file | grep $latency_type | awk '{print $2}')
  else
    log_message "Could not find latency in loadtest output ${drivernode_log_file}" >&2
    exit 1;
  fi

  if [[ -n $output_csv_file ]]; then
    # Example of input:
    # Stats for node under test, type 0
    #  RX: 0.65 MB/sec (208661843 bytes)
    #  TX: 0.12 MB/sec (38549952 bytes)
    #   #: 41.52 QPS (12748 queries)
    # min: 291.611 ms
    # avg: 427.125 ms
    # 50p: 395.040 ms
    # 90p: 579.294 ms
    # 95p: 665.092 ms
    # 99p: 777.239 ms
    # 99.9p: 1192.106 ms

    local total_bytes_rx=$(cat $drivernode_log_file | awk '/RX:/ {print substr($4,2)}')
    local total_bytes_tx=$(cat $drivernode_log_file | awk '/TX:/ {print substr($4,2)}')
    local rx_mbps=$(cat $drivernode_log_file | awk '/RX:/ {print $2;}')
    local tx_mbps=$(cat $drivernode_log_file | awk '/TX:/ {print $2;}')

    local total_queries=$(cat $drivernode_log_file | awk '/QPS/ {print substr($4,2);}')

    local min_ms=$(cat $drivernode_log_file | awk '/min:/ {print $2;}')
    local avg_ms=$(cat $drivernode_log_file | awk '/avg:/ {print $2;}')
    local p50_ms=$(cat $drivernode_log_file | awk '/50p:/ {print $2;}')
    local p90_ms=$(cat $drivernode_log_file | awk '/90p:/ {print $2;}')
    local p95_ms=$(cat $drivernode_log_file | awk '/95p:/ {print $2;}')
    local p99_ms=$(cat $drivernode_log_file | awk '/99p:/ {print $2;}')
    local p99_9_ms=$(cat $drivernode_log_file | awk '/99\.9p:/ {print $2;}')

    printf '%d,%d,%.2f,%.2f,' "$experiment_time" "$total_queries" "$3" "$qps" >> $output_csv_file
    printf '%d,%d,%.2f,%.2f,' "$total_bytes_rx" "$total_bytes_tx" "$rx_mbps" "$tx_mbps" >> $output_csv_file
    printf '%.3f,%.3f,%.3f,%.3f,' "$min_ms" "$avg_ms" "$p50_ms" "$p90_ms" >> $output_csv_file
    printf '%.3f,%.3f,%.3f\n' "$p95_ms" "$p99_ms" "$p99_9_ms" >> $output_csv_file

  fi

  eval $__output_qps="'$qps'"
  eval $__output_latency="'$latency'"

  sleep 10
}

collect_perf_record() {
    sleep 30
    if [ -f "${FEEDSIM_ROOT}/result/perf.data" ]; then
	    log_message "collect_perf_record: already exist"
      return 0
    fi
    log_message "collect_perf_record: collect perf"
    perf record -a -g -o ${FEEDSIM_ROOT}/result/perf.data -- sleep 5 >> ${FEEDSIM_ROOT}/LOGs/perf-record.log 2>&1
}

# Initialize our own variables:
experiment_time=120
wait_time=5
warmup_time=""
final_experiment_time=90
latency_type=""
latency_target=""
load_test_retries=3
output_csv_file=""
fixed_qps=""
auto_driver_threads=""
specified_driver_threads=""
num_logical_cpus="$(nproc)"
inst_num=""
is_autoscale="${IS_AUTOSCALE_RUN:-}"

OPTIND=1 # Reset is necessary if getopts was used previously in the script.  It is a good idea to make this local in a function.
while getopts "ht:f:w:m:s:q:an:o:-:" opt; do
  case "$opt" in
    h)
      show_help
      exit 0
      ;;
    t)
      experiment_time=$OPTARG
      ;;
    f)
      final_experiment_time=$OPTARG
      ;;
    w)
      wait_time=$OPTARG
      ;;
    m)
      warmup_time="$OPTARG"
      ;;
    s)
      latency_type=$(echo $OPTARG | tr ':' ' ' | awk '{print $1}')
      latency_target=$(echo $OPTARG | tr ':' ' ' | awk '{print $2}')
      ;;
    q)
      fixed_qps=$OPTARG
      ;;
    a)
      auto_driver_threads=1
      ;;
    n)
      specified_driver_threads=$OPTARG
      ;;
    o)
      output_csv_file=$OPTARG
      ;;
    -)
      case "$OPTARG" in
        inst-num)
          inst_num="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ))
          ;;
        is-autoscale)
          IS_AUTOSCALE_RUN="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ))
          ;;
        num-logical-cpus)
          num_logical_cpus="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ))
          ;;
        *)
          echo "Unknown option --$OPTARG" >&2
          exit 1
          ;;
      esac
      ;;
    '?')
      show_help >&2
      exit 1
      ;;
  esac
done
shift "$((OPTIND-1))" # Shift off the options and optional --.


if [ -z "$warmup_time" ]; then
  warmup_time="$experiment_time"
fi

SCRIPT_NAME="$(basename "$0")"
log_message "${SCRIPT_NAME}: DCPERF_PERF_RECORD=${DCPERF_PERF_RECORD:-0}"




# remaining argument is loadtest command
command=$@

# make sure latency_type and latency_target are specified
if [[ -z "$fixed_qps" ]] && ( [[ $latency_type = "" ]] || [[ $latency_target = "" ]] ); then
  log_message 'error: -s metric:target must be specified' >&2; exit 1
fi

# make sure latency_type is a recognized type
if [[ $latency_type != "avg" ]] && [[ $latency_type != "50p" ]] && \
   [[ $latency_type != "90p" ]] && [[ $latency_type != "95p" ]] && \
   [[ $latency_type != "99p" ]] && [[ $latency_type != "99.9p" ]]; then
  log_message 'error: metric must be avg|50p|90p|95p|99p|99.9p' >&2; exit 1
fi

# check to make sure experiment_time is an integer
if ! [[ $experiment_time =~ ^[0-9]+$ ]] ; then
 log_message "error: experiment_time ($experiment_time) is not an integer" >&2; exit 1
fi

# check to make sure latency_target is a float
if [[ -z "$fixed_qps" ]] && ! [[ $latency_target =~ ^[0-9]+([.][0-9]+)?$ ]] ; then
 log_message "error: latency_target ($latency_target) is not a float" >&2; exit 1
fi

# check to make sure first argument is a binary
type $1 >/dev/null 2>&1 || { log_message "The loadtest command does not appear to invoke a binary."; exit 1; }

# Set csv headers file, if path given
if [[ -n $output_csv_file ]]; then
  header="duration_secs,\
total_queries,\
requested_qps,\
achieved_qps,\
total_bytes_rx,\
total_bytes_tx,\
rx_MBps,\
tx_MBps,\
min_ms,\
avg_ms,\
50p_ms,\
90p_ms,\
95p_ms,\
99p_ms,\
99.9p_ms"

  echo $header > $output_csv_file
fi





# tell the user what we are doing
log_message "warmup_time: $warmup_time"
log_message "experiment_time: $experiment_time"
if [[ -z "$fixed_qps" ]]; then
  log_message "final_experiment_time: $final_experiment_time"
fi
if [[ -z "$fixed_qps" ]]; then
  log_message "Searching for QPS where $latency_type latency <= $latency_target msec"
else
  log_message "Running an experiment with QPS fixed at $fixed_qps and returns $latency_type latency"
fi
if [[ -n "$IS_AUTOSCALE_RUN" ]] && [[ "$IS_AUTOSCALE_RUN" -gt 1 ]]; then
  log_message "inst_num: $inst_num (autoscale run with ${IS_AUTOSCALE_RUN} instances)"
fi
log_message "auto_driver_threads: $auto_driver_threads"
log_message "command: $command \n"



# Calculate MAX_DRIVER_THREADS_DEFAULT based on allocated CPUs
IS_SMT_ON="$(cat /sys/devices/system/cpu/smt/active 2>/dev/null || echo 1)"
bc_max='define max (a, b) { if (a >= b) return (a); return (b); }'
if [[ "$IS_SMT_ON" = 1 ]]; then
    MAX_DRIVER_THREADS_DEFAULT="$(echo "scale=2; ${num_logical_cpus} / 5.0 + 0.5 " | bc )"
else
    MAX_DRIVER_THREADS_DEFAULT="$(echo "scale=2; ${num_logical_cpus} / 4.0 + 0.5 " | bc )"
fi
MAX_DRIVER_THREADS_DEFAULT="${MAX_DRIVER_THREADS_DEFAULT%.*}"
MAX_DRIVER_THREADS_DEFAULT="$(echo "${bc_max}; max(${MAX_DRIVER_THREADS_DEFAULT:-0}, 4)" | bc )"
max_driver_threads="$MAX_DRIVER_THREADS_DEFAULT"
log_message "MAX_DRIVER_THREADS_DEFAULT: $MAX_DRIVER_THREADS_DEFAULT (based on ${num_logical_cpus} CPUs, SMT: $IS_SMT_ON)"




# warm-up trials
if [ "$warmup_time" -gt 0 ]; then
  saved_experiment_time="$experiment_time"
  experiment_time="$warmup_time"
  run_load_type="WARMUP"
  log_message "WARMUP STARTED"
  calculate_driver_threads driver_threads ""
  run_loadtest peak_qps measured_latency "$driver_threads"
  log_message "WARMUP COMPLETED"
  log_message "$(printf "warmup qps = %.2f, latency = %.2f" $peak_qps $measured_latency)\n"
  experiment_time="$saved_experiment_time"
fi


# Fixed QPS run
if [[ -n "$fixed_qps" ]]; then
  fixed_qps_array=$(echo $fixed_qps | sed "s/,/ /g") # split fixed_qps by commas
  fixed_qps_count=$(echo $fixed_qps_array | wc -w) # count the number of fixed qps values provided

  # Single fixed QPS run
  if [ $fixed_qps_count -eq 1 ]; then
    if [ "${DCPERF_PERF_RECORD}" = 1 ] && ! [ -f "${FEEDSIM_ROOT}/result/perf.data" ]; then
        collect_perf_record &
        PERF_PID=$!
    fi
    run_load_type="EXPERIMENT"
    log_message "EXPERIMENT STARTED"
    run_loadtest_with_adaptive_scaling measured_qps measured_latency $fixed_qps
    log_message "EXPERIMENT COMPLETED"
    log_message "$(printf "final requested_qps = %.2f, measured_qps = %.2f, latency = %.2f" $fixed_qps $measured_qps $measured_latency) \n"

  # Multiple fixed QPS runs
  else
    for fixed_qps_el in $fixed_qps_array; do
      run_load_type="EXPERIMENT-${fixed_qps_el}"
      log_message "EXPERIMENT STARTED. QPS: ${fixed_qps_el}"
      run_loadtest_with_adaptive_scaling measured_qps measured_latency $fixed_qps_el
      log_message "EXPERIMENT COMPLETED. QPS: ${fixed_qps_el}"
      log_message "$(printf "final requested_qps = %.2f, measured_qps = %.2f, latency = %.2f" $fixed_qps_el $measured_qps $measured_latency) \n"
    done
  fi
  exit 0
fi





# find peak QPS
log_message "PEAK QPS STARTED"
run_load_type="PEAK-QPS"
calculate_driver_threads driver_threads ""
run_loadtest peak_qps measured_latency "$driver_threads"
log_message "PEAK QPS COMPLETED"
log_message "$(printf "peak qps = %.2f, latency = %.2f" $peak_qps $measured_latency)"

# Pad peak QPS
# TODO: Peak QPS is always underestimated by a lot. Why?
# TODO: GitHub issue to be created 
peak_qps=$(echo "$peak_qps*1.8"|bc)
log_message "$(printf "scaled peak qps = %.2f" $peak_qps)\n"





high_qps=$peak_qps
low_qps=1
cur_qps=$peak_qps
max_iters=25
n_iters=0

# binary search to approx. location
log_message "Binary Search Started \n"
loop_cond=$(echo "(($high_qps > $low_qps * 1.02) && $cur_qps > ($peak_qps * .1))" | bc)
while [[ $loop_cond -eq 1 ]]; do
  # calculate new QPS
  cur_qps=$(echo "scale=5; ($high_qps + $low_qps) / 2" | bc)

  # run experiment and report result
  run_load_type="BINARY-SEARCH-${cur_qps}"
  log_message "BINARY SEARCH ${cur_qps} STARTED"
  run_loadtest_with_adaptive_scaling measured_qps measured_latency $cur_qps
  log_message "BINARY SEARCH ${cur_qps} COMPLETED"
  log_message "$(printf "requested_qps = %.2f, measured_qps = %.2f, latency = %.2f\n" $cur_qps $measured_qps $measured_latency)"

  log_message "Binary Search Iteration $n_iters"
  log_message "Binary Search cur_qps: $cur_qps, low_qps: $low_qps, high_qps: $high_qps"
  log_message "Binary Search measured_qps: $measured_qps, measured_latency: $measured_latency\n"

  # set new QPS ranges
  latency_good=$(echo "$measured_latency <= $latency_target" | bc)
  if [[ $latency_good -eq 0 ]]; then
    high_qps=$cur_qps
  else
    low_qps=$cur_qps
    measured_qps_is_higher=$(echo "$measured_qps > $low_qps" | bc)
    if [[ $measured_qps_is_higher -eq 1 ]] ; then
      low_qps=$measured_qps
    fi
    measured_qps_gap=$(echo "$cur_qps > $measured_qps * 1.02" | bc)
    if [[ $measured_qps_gap -eq 1 ]] ; then
      high_qps=$(echo "scale=5; $high_qps*0.96" | bc)
    fi
  fi

  n_iters=$(echo "$n_iters + 1" | bc)

  log_message "(($high_qps > $low_qps * 1.02) && $cur_qps > ($peak_qps * .1))"
  loop_cond=$(echo "(($high_qps > $low_qps * 1.02) && $cur_qps > ($peak_qps * .1) && $n_iters < $max_iters)" | bc)
done
log_message "Binary Search Completed\n"




# do fine tuning (skip if the searching loop failed to converge within limit)
log_message "Fine Tuning Started\n"
loop_cond=$(echo "($measured_latency > ($latency_target*0.995) && $n_iters < $max_iters)" | bc)
while [[ $loop_cond -eq 1 ]]; do
  # calculate new QPS
  tuning_reduce_qps cur_qps $measured_latency $latency_target $cur_qps

  qps_cond=$(echo "$cur_qps > 4" | bc)
  if [ $qps_cond -eq 0 ] ; then
    break
  fi

  # run experiment and report result
  run_load_type="FINE-TUNING-${cur_qps}"
  log_message "FINE TUNING ${cur_qps} STARTED"
  calculate_driver_threads driver_threads "$cur_qps"
  run_loadtest measured_qps measured_latency "$driver_threads" $cur_qps
  log_message "FINE TUNING ${cur_qps} COMPLETED"
  log_message "$(printf "requested_qps = %.2f, measured_qps = %.2f, latency = %.2f" $cur_qps $measured_qps $measured_latency)\n"

  n_iters=$(echo "$n_iters + 1" | bc)
  loop_cond=$(echo "($measured_latency > ($latency_target*0.995) && $n_iters < $max_iters)" | bc)
done
log_message "Fine Tuning Completed\n"




# gap tuning
log_message "Gap Tuning Started\n"
loop_cond=$(echo "($cur_qps > ($measured_qps*1.02))" | bc)
while [[ $loop_cond -eq 1 ]]; do
  cur_qps=$(echo "scale=5; $cur_qps - (($cur_qps - $measured_qps)/2)" | bc)

  # run experiment and report result
  run_load_type="GAP-TUNING-${cur_qps}"
  log_message "GAP TUNING ${cur_qps} STARTED"
  calculate_driver_threads driver_threads "$cur_qps"
  run_loadtest measured_qps measured_latency "$driver_threads" $cur_qps
  log_message "GAP TUNING ${cur_qps} COMPLETED"
  log_message "$(printf "requested_qps = %.2f, measured_qps = %.2f, latency = %.2f" $cur_qps $measured_qps $measured_latency)"

  loop_cond=$(echo "($cur_qps > ($measured_qps*1.02))" | bc)
done
log_message "Gap Tuning Completed\n"





# Synchronization: wait for all instances to complete Gap Tuning
if [[ -n "$IS_AUTOSCALE_RUN" ]] && [[ "$IS_AUTOSCALE_RUN" -gt 1 ]]; then
    NUM_INSTANCES=$IS_AUTOSCALE_RUN
    num_ready_inst=$(grep -l "Gap Tuning Completed" "${FEEDSIM_ROOT}"/LOGs/search_qps.sh.*.log 2>/dev/null | wc -l)
    if [[ $num_ready_inst -lt $NUM_INSTANCES ]]; then
        log_message "[Instance $inst_num] Waiting for other instances to finish Gap Tuning stage."
        while [[ $num_ready_inst -lt $NUM_INSTANCES ]]; do
            sleep 1
            num_ready_inst=$(grep -l "Gap Tuning Completed" "${FEEDSIM_ROOT}"/LOGs/search_qps.sh.*.log 2>/dev/null | wc -l)
        done
        log_message "[Instance $inst_num] All instances completed Gap Tuning. Proceeding to final measurement."
    fi
fi




# do final measurement
log_message "FINAL MEASUREMENT STARTED"
experiment_time=$final_experiment_time
if [ "${DCPERF_PERF_RECORD}" = 1 ] && ! [ -f "${FEEDSIM_ROOT}/result/perf.data" ]; then
    collect_perf_record &
    PERF_PID=$!
fi
run_load_type="FINAL-MEASUREMENT"
calculate_driver_threads driver_threads "$cur_qps"
run_loadtest measured_qps measured_latency "$driver_threads" $cur_qps
log_message "FINAL MEASUREMENT COMPLETED"
log_message "$(printf "final requested_qps = %.2f, measured_qps = %.2f, latency = %.2f" $cur_qps $measured_qps $measured_latency)"

# report non-converging error if iteration reaches max tries
if [ "$n_iters" -ge "$max_iters" ]; then
    log_message "$(printf "error: binary search iterated %d times but latency still could not converge to target." "$n_iters")"
fi
log_message "FINAL MEASUREMENT SECTION COMPLETED\n"

# End of file
