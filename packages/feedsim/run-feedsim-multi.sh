#!/bin/bash
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

IS_FIXED_QPS=0
THIS_CMD="$0 $*"

if [[ "$THIS_CMD" =~ -q.*[0-9]+ ]]; then
    IS_FIXED_QPS=1
fi

FEEDSIM_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

# Delete and recreate LOGs directory
rm -rf "${FEEDSIM_ROOT}/LOGs"
mkdir -p "${FEEDSIM_ROOT}/LOGs"
rm -rf "${FEEDSIM_ROOT}/result"
mkdir -p "${FEEDSIM_ROOT}/result"

function log_message() {
    echo "${1}" | tee -a "${FEEDSIM_ROOT}/LOGs/run-feedsim-multi.sh.log"
}

FEEDSIM_LOG_PREFIX="${FEEDSIM_ROOT}/LOGs/run.sh."
NCPU="$(nproc)"
NUM_INSTANCES="$(( ( NCPU + 99 ) / 100 ))"

NUM_ICACHE_ITERATIONS="1600000"

SCRIPT_NAME="$(basename "$0")"
log_message "${SCRIPT_NAME}: DCPERF_PERF_RECORD=${DCPERF_PERF_RECORD:-0}"
log_message "Total CPUs: ${NCPU}, Default instances: ${NUM_INSTANCES}"

while [ $# -ne 0 ]; do
    case $1 in
        -n)
            if [[ "$2" -gt 0 ]]; then
                NUM_INSTANCES="$2"
                log_message "Setting NUM_INSTANCES to ${NUM_INSTANCES}"
            fi
            ;;
        -i)
            NUM_ICACHE_ITERATIONS="$2"
            ;;
        -h|--help)
            show_help >&2
            exit 1
            ;;
        *)  # end of input
            break
    esac

    case $1 in
        -n|-i)
            if [ -z "$2" ]; then
                log_message "Invalid option: '$1' requires an argument" 1>&2
                exit 1
            fi
            shift   # Additional shift for the argument
            ;;
    esac
    shift # pop the previously read argument
done



PORT=21212
PIDS=()

function get_cpu_range() {
    local __resultvar_range=$1
    local __resultvar_cpus=$2
    local total_instances="$3"
    local inst_id="$4"

    # Note: this assumes that SMT is either fully enabled or fully disabled. Odd number of total logical CPUs is not supported.
    # Also assumes that each physical core has 2 threads when SMT is enabled.
    has_smt="$(cat /sys/devices/system/cpu/smt/active 2>/dev/null || echo 0)"

    NPROC="$(nproc)"
    
    # Topology-based CPU allocation is disabled because:
    # 1. In containers (Docker/cgroups), /sys/devices/system/cpu shows HOST CPUs, not container limits
    # 2. The number of CPUs from topology may not match nproc (which respects cgroup limits)
    # 3. Fallback approach using nproc works correctly in both bare metal and containers
    #
    # # Try to build a mapping of physical cores to their thread siblings
    # # by reading actual CPU topology from sysfs
    # declare -A core_to_threads
    # declare -a physical_cores
    # topology_available=1
    # 
    # # Check if we're in a container (Docker/cgroup limits may not match sysfs)
    # in_container=0
    # if [ -f "/.dockerenv" ] || [ -f "/run/.containerenv" ] || grep -q "docker\|lxc" /proc/1/cgroup 2>/dev/null; then
    #     in_container=1
    #     echo "Container detected, skipping topology-based CPU allocation" >&2
    #     topology_available=0
    # fi
    # 
    # # Check if sysfs CPU directory exists
    # if [ "$topology_available" -eq 1 ] && [ ! -d "/sys/devices/system/cpu" ]; then
    #     topology_available=0
    # elif [ "$topology_available" -eq 1 ]; then
    #     for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
    #         # Check if glob pattern actually matched any files
    #         if [ ! -e "$cpu" ]; then
    #             topology_available=0
    #             break
    #         fi
    #         
    #         cpu_id="${cpu##*/cpu}"
    #         if [ -f "$cpu/topology/core_id" ]; then
    #             core_id=$(cat "$cpu/topology/core_id" 2>/dev/null)
    #             if [ -z "$core_id" ]; then
    #                 topology_available=0
    #                 break
    #             fi
    #         else
    #             topology_available=0
    #             break
    #         fi
    #         
    #         # Add this CPU to the list for its physical core
    #         if [ -z "${core_to_threads[$core_id]}" ]; then
    #             core_to_threads[$core_id]="$cpu_id"
    #             physical_cores+=("$core_id")
    #         else
    #             core_to_threads[$core_id]="${core_to_threads[$core_id]},$cpu_id"
    #         fi
    #     done
    # fi
    # 
    # # Check if topology reading succeeded and matches nproc
    # if [ "$topology_available" -eq 1 ] && [ "${#physical_cores[@]}" -gt 0 ]; then
    #     # Validate: total logical CPUs from topology should match nproc
    #     total_logical_cpus=0
    #     for core_id in "${physical_cores[@]}"; do
    #         IFS=',' read -ra threads <<< "${core_to_threads[$core_id]}"
    #         total_logical_cpus=$((total_logical_cpus + ${#threads[@]}))
    #     done
    #     
    #     if [ "$total_logical_cpus" -ne "$NPROC" ]; then
    #         echo "Warning: Topology CPUs ($total_logical_cpus) != nproc ($NPROC), using fallback" >&2
    #         topology_available=0
    #     fi
    # fi
    # 
    # # Check if topology reading succeeded
    # if [ "$topology_available" -eq 1 ] && [ "${#physical_cores[@]}" -gt 0 ]; then
    #     # Use topology-based approach
    #     echo "Using topology-based CPU allocation" >&2
    #     
    #     # Sort physical cores numerically
    #     IFS=$'\n' physical_cores=($(sort -n <<<"${physical_cores[*]}"))
    #     unset IFS
    #     
    #     NCORES="${#physical_cores[@]}"
    #     CORES_PER_INST="$((NCORES / total_instances))"
    #     REMAINING_CORES="$((NCORES - CORES_PER_INST * total_instances))"
    #     EXTRA_CORE=0
    #     OFFSET=0
    #     
    #     if [ "$inst_id" -lt "$REMAINING_CORES" ]; then
    #         EXTRA_CORE=1
    #         OFFSET="$inst_id"
    #     else
    #         EXTRA_CORE=0
    #         OFFSET="$REMAINING_CORES"
    #     fi
    #
    #     CORE_START="$((CORES_PER_INST * inst_id + OFFSET))"
    #     CORE_END="$((CORE_START + CORES_PER_INST + EXTRA_CORE - 1))"
    #     
    #     # Collect all CPUs (including SMT siblings) for the assigned physical cores
    #     cpu_list=()
    #     for ((i=CORE_START; i<=CORE_END; i++)); do
    #         core_id="${physical_cores[$i]}"
    #         # Split comma-separated thread list and add each CPU
    #         IFS=',' read -ra threads <<< "${core_to_threads[$core_id]}"
    #         cpu_list+=("${threads[@]}")
    #     done
    #     
    #     # Sort CPUs numerically for cleaner output
    #     IFS=$'\n' sorted_cpus=($(sort -n <<<"${cpu_list[*]}"))
    #     unset IFS
    #     
    #     # Build compact CPU range string
    #     RES=$(echo "${sorted_cpus[@]}" | tr ' ' ',' | sed 's/,$//')
    #     
    #     # Calculate number of logical CPUs
    #     NUM_LOGICAL_CPUS="${#cpu_list[@]}"
    #     
    #     # Create compact display string for logging
    #     DISPLAY_RANGE="${sorted_cpus[0]}-${sorted_cpus[-1]}"
    # else
    
    # Use simple CPU allocation based on nproc (works in containers and bare metal)
    
    if [ "$has_smt" -eq 1 ]; then
        NCORES="$((NPROC / 2))"
    else
        NCORES="$NPROC"
    fi
    
    CORES_PER_INST="$((NCORES / total_instances))"
    REMAINING_CORES="$((NCORES - CORES_PER_INST * total_instances))"
    EXTRA_CORE=0
    OFFSET=0
    
    if [ "$inst_id" -lt "$REMAINING_CORES" ]; then
        EXTRA_CORE=1
        OFFSET="$inst_id"
    else
        EXTRA_CORE=0
        OFFSET="$REMAINING_CORES"
    fi

    PHY_CORE_BASE="$((CORES_PER_INST * inst_id + OFFSET))"
    PHY_CORE_END="$((PHY_CORE_BASE + CORES_PER_INST + EXTRA_CORE - 1))"

    # Calculate number of logical CPUs (physical cores * threads per core)
    NUM_PHYSICAL_CORES="$((CORES_PER_INST + EXTRA_CORE))"
    if [ "$has_smt" -eq 1 ]; then
        NUM_LOGICAL_CPUS="$((NUM_PHYSICAL_CORES * 2))"
    else
        NUM_LOGICAL_CPUS="$NUM_PHYSICAL_CORES"
    fi

    RES="${PHY_CORE_BASE}-${PHY_CORE_END}"
    if [ "$has_smt" -eq 1 ]; then
        SMT_BASE="$((NPROC / 2 + CORES_PER_INST * inst_id + OFFSET))"
        SMT_END="$((SMT_BASE + CORES_PER_INST + EXTRA_CORE - 1))"
        RES="${RES},${SMT_BASE}-${SMT_END}"
    fi
    
    DISPLAY_RANGE="$RES"

    log_message "Instance $((inst_id + 1)): CPUs ${DISPLAY_RANGE} (${NUM_LOGICAL_CPUS} logical CPUs)"
    
    # Return values by setting the passed variable names
    eval $__resultvar_range="'$RES'"
    eval $__resultvar_cpus="'$NUM_LOGICAL_CPUS'"
}


# shellcheck disable=SC2086
for i in $(seq 1 ${NUM_INSTANCES}); do
    get_cpu_range CORE_RANGE NUM_LOGICAL_CPUS "${NUM_INSTANCES}" "$((i - 1))"
    CMD="IS_AUTOSCALE_RUN=${NUM_INSTANCES} DCPERF_PERF_RECORD=${DCPERF_PERF_RECORD:-0} taskset --cpu-list ${CORE_RANGE} ${FEEDSIM_ROOT}/run.sh -p ${PORT} -i ${NUM_ICACHE_ITERATIONS} -o  ${FEEDSIM_ROOT}/result/feedsim_results-${i}.txt --inst-num ${i} --num-logical-cpus ${NUM_LOGICAL_CPUS} $*"
    log_message "$CMD"
    echo "$CMD" > "${FEEDSIM_LOG_PREFIX}${i}.log"
    # shellcheck disable=SC2068,SC2069
    IS_AUTOSCALE_RUN=${NUM_INSTANCES} DCPERF_PERF_RECORD=${DCPERF_PERF_RECORD:-0} stdbuf -i0 -o0 -e0 taskset --cpu-list "${CORE_RANGE}" "${FEEDSIM_ROOT}"/run.sh -p "${PORT}" -i "${NUM_ICACHE_ITERATIONS}" -o "${FEEDSIM_ROOT}/result/feedsim_results-${i}.txt" --inst-num "${i}" --num-logical-cpus "${NUM_LOGICAL_CPUS}" "$@" 2>&1 | tee -a "${FEEDSIM_LOG_PREFIX}${i}.log" &
    PIDS+=("$!")
    PORT=$((PORT + 1))
done

# shellcheck disable=SC2068,SC2069
for pid in ${PIDS[@]}; do
    wait "$pid" 2>&1 >/dev/null
done

BC_MAX_FN='define max (a, b) { if (a >= b) return (a); return (b); }'
BC_MIN_FN='define min (a, b) { if (a <= b) return (a); return (b); }'
function analyze_and_print_results() {
    log_message "{"
    total_req_qps=0.0
    total_actual_qps=0.0
    avg_latency=0.0
    successful_insts=0
    target_percentile=""
    target_latency=0.0
    min_qps=99999.9
    max_qps=0.0
    max_req_qps=0.0

    # shellcheck disable=SC2086
    # TODO: This does not work when there are multiple fixed QPS runs in each instance
    for i in $(seq 1 ${NUM_INSTANCES}); do
        final_requested_qps="$(grep -oP 'final requested_qps = \K[0-9.]+' "${FEEDSIM_LOG_PREFIX}${i}.log")"
        if [ -z "$final_requested_qps" ]; then
            min_qps=0.0
            continue
        fi
        successful_insts="$((successful_insts + 1))"
        measured_qps="$(grep -oP 'final.*measured_qps = \K[0-9.]+' "${FEEDSIM_LOG_PREFIX}${i}.log")"
        latency="$(grep -oP 'final.*latency = \K[0-9.]+' "${FEEDSIM_LOG_PREFIX}${i}.log")"
        target_percentile="$(grep -oP 'Searching for QPS where \K[0-9p]+' "${FEEDSIM_LOG_PREFIX}${i}.log")"
        target_latency="$(grep -oP 'Searching for.*latency <= \K[0-9]+(?= msec)' "${FEEDSIM_LOG_PREFIX}${i}.log")"
        log_message "    \"${i}\": {\"final_requested_qps\": ${final_requested_qps}, \"final_achieved_qps\": ${measured_qps}, \"final_latency_msec\": ${latency}},"
        total_req_qps="$(echo "${total_req_qps} + ${final_requested_qps}" | bc)"
        total_actual_qps="$(echo "${total_actual_qps} + ${measured_qps}" | bc)"
        avg_latency="$(echo "${avg_latency} + ${latency}" | bc)"
        min_qps="$(echo "${BC_MIN_FN}; min(${min_qps}, ${measured_qps})" | bc)"
        max_qps="$(echo "${BC_MAX_FN}; max(${max_qps}, ${measured_qps})" | bc)"
        max_req_qps="$(echo "${BC_MAX_FN}; max(${max_req_qps}, ${final_requested_qps})" | bc)"
    done

    avg_latency="$(echo "scale=2; 1.0 * ${avg_latency} / ${successful_insts}" | bc)"
    log_message "    \"overall\": {\"final_requested_qps\": ${total_req_qps}, \"final_achieved_qps\": ${total_actual_qps}, \"average_latency_msec\": ${avg_latency}},"
    log_message "    \"target_percentile\": \"${target_percentile}\","
    log_message "    \"target_latency_msec\": \"${target_latency}\","
    log_message "    \"spawned_instances\": \"${NUM_INSTANCES}\","
    log_message "    \"successful_instances\": ${successful_insts},"
    log_message "    \"min_qps\": ${min_qps},"
    log_message "    \"max_qps\": ${max_qps},"
    log_message "    \"is_fixed_qps\": ${IS_FIXED_QPS}"
    log_message "}"
    if [[ "$(echo "${min_qps} < 0.8 * ${max_qps}" | bc)" = "1" ]]; then
        # ceil(max_req_qps)
        echo "(${max_req_qps} + 1) / 1" | bc  > ${FEEDSIM_ROOT}/LOGs/max_req_qps
        return 1
    else
        return 0
    fi
}

is_unstable_run=0
# shellcheck disable=SC2069
if /usr/bin/env jq -h 2>&1 >/dev/null; then
    analyze_and_print_results | jq
    is_unstable_run="${PIPESTATUS[0]}"
else
    analyze_and_print_results
    is_unstable_run="$?"
fi

# rerun this program with fixed qps if detecting high variance
if [[ "$is_unstable_run" = 1 ]] && [[ "$IS_FIXED_QPS" = 0 ]] && [[ -z "$IS_RERUN" ]]; then
    max_req_qps="$(cat ${FEEDSIM_ROOT}/LOGs/max_req_qps)"
    log_message "Detected unstable run - rerunning with fixed QPS at ${max_req_qps}..."
    # shellcheck disable=SC2068
    sleep 60
    IS_RERUN=1 $THIS_CMD -q "${max_req_qps}"
fi
