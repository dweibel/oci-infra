#!/bin/sh
while true; do
    CPU_USAGE=$(top -bn1 | grep "CPU:" | awk '{print int($2)}')
    if [ -z "$CPU_USAGE" ]; then CPU_USAGE=0; fi
    if [ "$CPU_USAGE" -lt 15 ]; then
        echo "CPU usage ${CPU_USAGE}% - running stress-ng"
        stress-ng --cpu 1 --timeout 118s --cpu-load 80
    else
        echo "CPU usage ${CPU_USAGE}% - skipping stress-ng"
    fi
    curl -s https://www.oracle.com > /dev/null
    sleep 2
done
