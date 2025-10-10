#!/bin/bash                                                                                                                                                                                                                          
# monitor_container.sh                                                                                                                                                                                                               
# Usage: ./monitor_container.sh <container_id_or_name> <interval_seconds> <duration_seconds> [log_directory]                                                                                                                         
                                                                                                                                                                                                                                     
CONTAINER_ID=$1                                                                                                                                                                                                                      
INTERVAL=$2                                                                                                                                                                                                                          
DURATION=$3                                                                                                                                                                                                                          
LOGDIR=${4:-.}   # Default to current directory if not provided                                                                                                                                                                      
LOGFILE="$LOGDIR/container_${CONTAINER_ID}_size.log"                                                                                                                                                                                 
                                                                                                                                                                                                                                     
if [ -z "$CONTAINER_ID" ] || [ -z "$INTERVAL" ] || [ -z "$DURATION" ]; then                                                                                                                                                          
            echo "Usage: $0 <container_id_or_name> <interval_seconds> <duration_seconds> [log_directory]"                                                                                                                            
                exit 1                                                                                                                                                                                                               
fi                                                                                                                                                                                                                                   
                                                                                                                                                                                                                                     
# Ensure log directory exists                                                                                                                                                                                                        
mkdir -p "$LOGDIR"                                                                                                                                                                                                                   
                                                                                                                                                                                                                                     
#Function to convert bytes into KB/MB/GB                                                                                                                                                                                             
human_readable() {                                                                                                                                                                                                                   
        local size=$1                                                                                                                                                                                                                
        local unit="B"                                                                                                                                                                                                               
        if [ "$size" -ge 1073741824 ]; then                                                                                                                                                                                          
                size=$(awk "BEGIN {printf \"%.2f\", $size/1073741824}")                                                                                                                                                              
                unit="GB"                                                                                                                                                                                                            
        elif [ "$size" -ge 1048576 ]; then                                                                                                                                                                                           
                size=$(awk "BEGIN {printf \"%.2f\", $size/1048576}")                                                                                                                                                                 
                unit="MB"                                                                                                                                                                                                            
        elif [ "$size" -ge 1024 ]; then                                                                                                                                                                                              
                size=$(awk "BEGIN {printf \"%.2f\", $size/1024}")                                                                                                                                                                    
                unit="KB"                                                                                                                                                                                                            
        fi                                                                                                                                                                                                                           
        echo "${size}${unit}"                                                                                                                                                                                                        
}                                                                                                                                                                                                                                    
                                                                                                                                                                                                                                     
# Print Summaries                                                                                                                                                                                                                    
print_summary() {                                                                                                                                                                                                                    
        #--- Compute statistics ---                                                                                                                                                                                                  
        if [ ${#RAW_VALUES[@]} -gt 0 ]; then                                  
                sorted=($(printf "%s\n" "${RAW_VALUES[@]}" | sort -n))                                                                                                                                                               
                count=${#sorted[@]}

                min=${sorted[0]}
                max=${sorted[$((count-1))]}

                # Mean
                sum=0
                for v in "${sorted[@]}"; do
                        sum=$((sum + v))
                done
                mean=$((sum / count))

                echo ""
                echo "Summary for container $CONTAINER_ID:"
                echo "Min size:     $(human_readable $min)"
                echo "Max size:     $(human_readable $max)"
                echo "Mean size:    $(human_readable $mean)"

                echo "Summary for container $CONTAINER_ID:" >> "$LOGFILE"
                echo "Min size:     $(human_readable $min)" >> "$LOGFILE"
                echo "Max size:     $(human_readable $max)" >> "$LOGFILE"
                echo "Mean size:    $(human_readable $mean)" >> "$LOGFILE"
        else
                echo "No data collected."
        fi
}
trap "echo ''; echo 'Generating summary...'; print_summary; exit 0" SIGINT SIGTERM

# Start Monitoring
echo "Monitoring container: $CONTAINER_ID every $INTERVAL seconds for $DURATION seconds"
echo "Logging to: $LOGFILE"
echo "timestamp,container,size_rw_bytes,size_rootfs_bytes" > "$LOGFILE"

START_TIME=$(date +%s)
RAW_VALUES=()

while true; do
        NOW=$(date +%s)
        ELAPSED=$((NOW - START_TIME))

        if [ "$ELAPSED" -ge "$DURATION" ]; then
                echo "Finished monitoring after $DURATION seconds."
                break

       fi

        TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
        SIZE_INFO=$(docker inspect --size "$CONTAINER_ID" \
               --format '{{.Name}},{{.SizeRw}},{{.SizeRootFs}}' 2>/dev/null)

        if [ -z "$SIZE_INFO" ]; then
                echo "$TIMESTAMP,ERROR: container not found or stopped" >> "$LOGFILE"
                break
        else
                CONTAINER_NAME=$(echo "$SIZE_INFO" | cut -d',' -f1)
                SIZE_RW=$(echo "$SIZE_INFO" | cut -d',' -f2)
                SIZE_ROOTFS=$(echo "$SIZE_INFO" | cut -d',' -f3)

                HRW=$(human_readable "$SIZE_RW")
                HROOT=$(human_readable "$SIZE_ROOTFS")

                echo "$TIMESTAMP,$CONTAINER_NAME,$HRW,$HROOT" >> "$LOGFILE"
                RAW_VALUES+=("$SIZE_RW")
        fi

        sleep "$INTERVAL"
done

print_summary
