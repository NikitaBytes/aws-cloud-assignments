#!/bin/bash
# Пример: ./curl.sh <ALB_DNS_NAME> 20 60
HOST="$1"           # DNS ALB
THREADS="${2:-10}"  # кол-во параллельных потоков
DURATION="${3:-60}" # длительность в секундах

if [ -z "$HOST" ]; then
  echo "Usage: $0 <alb_dns_name> [threads] [duration_seconds]"
  exit 1
fi

echo "Starting load: $THREADS threads, $DURATION seconds each..."

for i in $(seq 1 "$THREADS"); do
  (
    end=$((SECONDS + DURATION))
    while [ $SECONDS -lt $end ]; do
      curl -s "http://$HOST/" > /dev/null
    done
  ) &
done

wait
echo "Done."