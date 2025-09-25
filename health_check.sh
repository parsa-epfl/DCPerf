#!/bin/bash
set -e

LOG_DIR="$PWD/LOGs"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

mkdir -p $LOG_DIR

# Run System Checks
./benchpress_cli.py list | tee "$LOG_DIR/list_$TIMESTAMP.log"
./benchpress_cli.py system_check | tee "$LOG_DIR/system_check_$TIMESTAMP.log"

# Run Health Checks
./benchpress_cli.py run health_check -r client &
CLIENT_PID=$!

./benchpress_cli.py run health_check -r server -i "{\"clients\": \"$(hostname -i)\"}" |  tee "$LOG_DIR/health_check_$TIMESTAMP.log"

kill $CLIENT_PID || true
wait $CLIENT_PID 2>/dev/null || true

exec bash

