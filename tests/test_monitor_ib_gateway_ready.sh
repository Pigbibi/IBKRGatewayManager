#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
monitor_script="$repo_dir/scripts/monitor_ib_gateway_ready.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

readiness_script="$tmp_dir/readiness.sh"
recovery_script="$tmp_dir/recovery.sh"
state_file="$tmp_dir/state"
call_log="$tmp_dir/calls.log"

cat >"$readiness_script" <<'SH'
#!/usr/bin/env bash
printf 'probe\n' >>"$CALL_LOG"
exit "${PROBE_EXIT_CODE:-0}"
SH
cat >"$recovery_script" <<'SH'
#!/usr/bin/env bash
printf 'recover\n' >>"$CALL_LOG"
exit "${RECOVERY_EXIT_CODE:-0}"
SH
chmod +x "$readiness_script" "$recovery_script"

base_env=(
  CALL_LOG="$call_log"
  IB_GATEWAY_READINESS_SCRIPT="$readiness_script"
  IB_GATEWAY_RECOVERY_SCRIPT="$recovery_script"
  IB_GATEWAY_HEALTHCHECK_STATE_FILE="$state_file"
  IB_GATEWAY_HEALTHCHECK_INTERVAL_SECONDS=900
  IB_GATEWAY_EXECUTION_WINDOW_INTERVAL_SECONDS=300
  IB_GATEWAY_EXECUTION_WINDOW_TIMES=09:45
  IB_GATEWAY_EXECUTION_WINDOW_MINUTES=60
  IB_GATEWAY_EXECUTION_WINDOW_TIMEZONE=America/New_York
  IB_GATEWAY_HEALTHCHECK_FAILURE_THRESHOLD=2
)

env "${base_env[@]}" IB_GATEWAY_HEALTHCHECK_NOW_EPOCH=1787832000 \
  bash "$monitor_script" live
test "$(tr '\n' ' ' <"$call_log")" = "probe "
grep -Fxq 'failure_count=0' "$state_file"

env "${base_env[@]}" IB_GATEWAY_HEALTHCHECK_NOW_EPOCH=1787832300 \
  bash "$monitor_script" live
test "$(wc -l <"$call_log")" -eq 1

if env "${base_env[@]}" PROBE_EXIT_CODE=1 IB_GATEWAY_HEALTHCHECK_NOW_EPOCH=1787838300 \
  bash "$monitor_script" live; then
  echo "First failed readiness probe unexpectedly succeeded." >&2
  exit 1
fi
test "$(tr '\n' ' ' <"$call_log")" = "probe probe "
grep -Fxq 'failure_count=1' "$state_file"

env "${base_env[@]}" PROBE_EXIT_CODE=1 IB_GATEWAY_HEALTHCHECK_NOW_EPOCH=1787838600 \
  bash "$monitor_script" live
test "$(tr '\n' ' ' <"$call_log")" = "probe probe probe recover "
grep -Fxq 'failure_count=0' "$state_file"
