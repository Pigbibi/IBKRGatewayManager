#!/usr/bin/env bash
set -euo pipefail

container_name="${CONTAINER_NAME:-ib-gateway}"
bot_path="/home/ibgateway/2fa_bot.py"
bot_log="/home/ibgateway/2fa.log"

if ! docker inspect "$container_name" >/dev/null 2>&1; then
  echo "Container '$container_name' not found; watcher will retry later."
  exit 0
fi

if [ "$(docker inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null)" != "true" ]; then
  echo "Container '$container_name' is not running; watcher will retry later."
  exit 0
fi

if docker exec "$container_name" pgrep -f 2fa_bot.py >/dev/null 2>&1; then
  echo "2FA bot already running in '$container_name'."
  exit 0
fi

docker exec -d "$container_name" bash -lc "nohup python3 $bot_path > $bot_log 2>&1 &"
sleep 2

if docker exec "$container_name" pgrep -f 2fa_bot.py >/dev/null 2>&1; then
  echo "Started 2FA bot in '$container_name'."
  exit 0
fi

echo "Failed to start 2FA bot in '$container_name'." >&2
exit 1
