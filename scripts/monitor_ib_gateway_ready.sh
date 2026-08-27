#!/usr/bin/env bash
set -euo pipefail

# Run a cheap, read-only Gateway readiness probe on an adaptive cadence.  The
# systemd timer wakes every few minutes, but this script only opens an IB API
# session every 15 minutes outside configured execution windows.  Two
# consecutive failed probes are required before the existing recovery script
# is allowed to restart or recreate the Gateway container.

script_dir="$(cd "$(dirname "$0")" && pwd)"
gateway_mode="${1:-${IB_GATEWAY_MODE:-paper}}"
normal_interval_seconds="${IB_GATEWAY_HEALTHCHECK_INTERVAL_SECONDS:-900}"
execution_window_interval_seconds="${IB_GATEWAY_EXECUTION_WINDOW_INTERVAL_SECONDS:-300}"
execution_window_times="${IB_GATEWAY_EXECUTION_WINDOW_TIMES:-09:45,15:45}"
execution_window_minutes="${IB_GATEWAY_EXECUTION_WINDOW_MINUTES:-60}"
execution_window_timezone="${IB_GATEWAY_EXECUTION_WINDOW_TIMEZONE:-America/New_York}"
failure_threshold="${IB_GATEWAY_HEALTHCHECK_FAILURE_THRESHOLD:-2}"
probe_timeout_seconds="${IB_GATEWAY_HEALTHCHECK_PROBE_TIMEOUT_SECONDS:-30}"
state_file="${IB_GATEWAY_HEALTHCHECK_STATE_FILE:-/var/lib/ib_gateway_healthcheck/default.state}"
readiness_script="${IB_GATEWAY_READINESS_SCRIPT:-$script_dir/wait_for_ib_gateway_ready.sh}"
recovery_script="${IB_GATEWAY_RECOVERY_SCRIPT:-$script_dir/recover_ib_gateway_ready.sh}"
configured_now_epoch="${IB_GATEWAY_HEALTHCHECK_NOW_EPOCH:-}"

is_positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

for value_name in \
  normal_interval_seconds \
  execution_window_interval_seconds \
  execution_window_minutes \
  failure_threshold \
  probe_timeout_seconds; do
  value="${!value_name}"
  if ! is_positive_integer "$value"; then
    echo "$value_name must be a positive integer." >&2
    exit 2
  fi
done

if [ -n "$configured_now_epoch" ]; then
  if ! [[ "$configured_now_epoch" =~ ^[0-9]+$ ]]; then
    echo "IB_GATEWAY_HEALTHCHECK_NOW_EPOCH must be a non-negative integer." >&2
    exit 2
  fi
  now_epoch="$configured_now_epoch"
else
  now_epoch="$(date +%s)"
fi

state_dir="$(dirname "$state_file")"
install -d -m 700 "$state_dir"

last_check_epoch=0
failure_count=0
if [ -f "$state_file" ]; then
  while IFS='=' read -r key value; do
    case "$key" in
      last_check_epoch)
        if [[ "$value" =~ ^[0-9]+$ ]]; then
          last_check_epoch="$value"
        fi
        ;;
      failure_count)
        if [[ "$value" =~ ^[0-9]+$ ]]; then
          failure_count="$value"
        fi
        ;;
    esac
  done <"$state_file"
fi

write_state() {
  local next_last_check_epoch="$1"
  local next_failure_count="$2"
  local temporary_file="${state_file}.tmp.$$"

  umask 077
  {
    printf 'last_check_epoch=%s\n' "$next_last_check_epoch"
    printf 'failure_count=%s\n' "$next_failure_count"
  } >"$temporary_file"
  mv -f "$temporary_file" "$state_file"
}

execution_window_state="$(
  EXECUTION_WINDOW_TIMES="$execution_window_times" \
  EXECUTION_WINDOW_MINUTES="$execution_window_minutes" \
  EXECUTION_WINDOW_TIMEZONE="$execution_window_timezone" \
  EXECUTION_WINDOW_NOW_EPOCH="$now_epoch" \
    python3 - <<'PY'
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo
import os

raw_times = os.environ["EXECUTION_WINDOW_TIMES"].strip()
window_minutes = int(os.environ["EXECUTION_WINDOW_MINUTES"])
timezone_name = os.environ["EXECUTION_WINDOW_TIMEZONE"].strip()
now_epoch = int(os.environ["EXECUTION_WINDOW_NOW_EPOCH"])
if not raw_times:
    print("false")
    raise SystemExit(0)

try:
    timezone = ZoneInfo(timezone_name)
except Exception as exc:
    raise SystemExit(f"invalid execution-window timezone: {timezone_name}") from exc

now = datetime.fromtimestamp(now_epoch, timezone)
window = timedelta(minutes=window_minutes)
times = []
for item in raw_times.split(","):
    text = item.strip()
    try:
        parsed = datetime.strptime(text, "%H:%M").time()
    except ValueError as exc:
        raise SystemExit(f"invalid execution-window time: {text}") from exc
    times.append(parsed)

for day_offset in (-1, 0, 1):
    date = (now + timedelta(days=day_offset)).date()
    for scheduled_time in times:
        scheduled = datetime.combine(date, scheduled_time, timezone)
        if abs(now - scheduled) <= window:
            print("true")
            raise SystemExit(0)
print("false")
PY
)"

case "$execution_window_state" in
  true)
    minimum_interval_seconds="$execution_window_interval_seconds"
    cadence_label="execution-window"
    ;;
  false)
    minimum_interval_seconds="$normal_interval_seconds"
    cadence_label="normal"
    ;;
  *)
    echo "Unable to determine IB Gateway execution-window cadence." >&2
    exit 2
    ;;
esac

if [ "$last_check_epoch" -gt 0 ] && [ $((now_epoch - last_check_epoch)) -lt "$minimum_interval_seconds" ]; then
  echo "Skipping IB Gateway readiness probe: ${cadence_label} cadence has not elapsed."
  exit 0
fi

echo "Running read-only IB Gateway readiness probe (${cadence_label} cadence)."
set +e
IB_GATEWAY_READY_TIMEOUT_SECONDS="$probe_timeout_seconds" \
IB_GATEWAY_READY_STABILITY_SECONDS=0 \
  bash "$readiness_script" "$gateway_mode"
probe_status=$?
set -e

if [ "$probe_status" -eq 0 ]; then
  write_state "$now_epoch" 0
  echo "IB Gateway API readiness probe succeeded."
  exit 0
fi

next_failure_count=$((failure_count + 1))
write_state "$now_epoch" "$next_failure_count"
if [ "$next_failure_count" -lt "$failure_threshold" ]; then
  echo "IB Gateway API readiness probe failed (${next_failure_count}/${failure_threshold}); recovery is deferred until the threshold is reached." >&2
  exit "$probe_status"
fi

echo "IB Gateway API readiness probe failed ${next_failure_count} consecutive times; starting guarded recovery." >&2
set +e
bash "$recovery_script" "$gateway_mode"
recovery_status=$?
set -e

if [ "$recovery_status" -eq 0 ]; then
  write_state "$now_epoch" 0
  echo "IB Gateway guarded recovery completed successfully."
else
  echo "IB Gateway guarded recovery did not complete successfully." >&2
fi
exit "$recovery_status"
