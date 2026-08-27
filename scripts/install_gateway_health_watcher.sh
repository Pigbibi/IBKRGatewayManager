#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="${REPO_DIR:-$(cd "${script_dir}/.." && pwd)}"
systemd_dir="${SYSTEMD_DIR:-/etc/systemd/system}"
systemctl_bin="${SYSTEMCTL_BIN:-systemctl}"
container_name="${CONTAINER_NAME:-${IB_GATEWAY_CONTAINER_NAME:-ib-gateway}}"
compose_service_name="${IB_GATEWAY_COMPOSE_SERVICE_NAME:-ib-gateway}"
unit_suffix="${IB_GATEWAY_UNIT_SUFFIX:-}"
gateway_mode="${1:-${IB_GATEWAY_MODE:-paper}}"
compose_file="${COMPOSE_FILE:-docker-compose.yml}"
healthcheck_tick_seconds="${IB_GATEWAY_HEALTHCHECK_TICK_SECONDS:-300}"
health_interval_seconds="${IB_GATEWAY_HEALTHCHECK_INTERVAL_SECONDS:-900}"
execution_window_interval_seconds="${IB_GATEWAY_EXECUTION_WINDOW_INTERVAL_SECONDS:-300}"
execution_window_times="${IB_GATEWAY_EXECUTION_WINDOW_TIMES:-09:45,15:45}"
execution_window_minutes="${IB_GATEWAY_EXECUTION_WINDOW_MINUTES:-60}"
execution_window_timezone="${IB_GATEWAY_EXECUTION_WINDOW_TIMEZONE:-America/New_York}"
failure_threshold="${IB_GATEWAY_HEALTHCHECK_FAILURE_THRESHOLD:-2}"
probe_timeout_seconds="${IB_GATEWAY_HEALTHCHECK_PROBE_TIMEOUT_SECONDS:-30}"
daily_restart_calendar="${IB_GATEWAY_DAILY_RESTART_ON_CALENDAR:-*-*-* 10:30:00 UTC}"

. "$script_dir/ibkr_gateway_units.sh"
resolve_ibkr_gateway_unit_names "$container_name" "$unit_suffix"
resolved_unit_suffix="$(resolve_ibkr_gateway_unit_suffix "$container_name" "$unit_suffix")"
if [ -n "$resolved_unit_suffix" ]; then
  default_lock_file="/var/lock/ib_gateway_recovery_${resolved_unit_suffix}.lock"
else
  default_lock_file="/var/lock/ib_gateway_recovery.lock"
fi
recovery_lock_file="${IB_GATEWAY_RECOVERY_LOCK_FILE:-$default_lock_file}"
if [ -n "$resolved_unit_suffix" ]; then
  default_state_file="/var/lib/ib_gateway_healthcheck/${resolved_unit_suffix}.state"
else
  default_state_file="/var/lib/ib_gateway_healthcheck/default.state"
fi
state_file="${IB_GATEWAY_HEALTHCHECK_STATE_FILE:-$default_state_file}"

install -d "$systemd_dir"

cat >"$systemd_dir/$IBKR_GATEWAY_HEALTHCHECK_SERVICE" <<EOF
[Unit]
Description=Adaptively check and recover IBKR Gateway API readiness
After=docker.service network-online.target
Wants=docker.service network-online.target

[Service]
Type=oneshot
WorkingDirectory=$repo_dir
Environment=IB_GATEWAY_CONTAINER_NAME=$container_name
Environment=IB_GATEWAY_COMPOSE_SERVICE_NAME=$compose_service_name
Environment=IB_GATEWAY_MODE=$gateway_mode
Environment=COMPOSE_FILE=$compose_file
Environment=IB_GATEWAY_RECOVERY_LOCK_FILE=$recovery_lock_file
Environment=IB_GATEWAY_RECOVERY_LOCK_WAIT_SECONDS=0
Environment=IB_GATEWAY_HEALTHCHECK_INTERVAL_SECONDS=$health_interval_seconds
Environment=IB_GATEWAY_EXECUTION_WINDOW_INTERVAL_SECONDS=$execution_window_interval_seconds
Environment=IB_GATEWAY_EXECUTION_WINDOW_TIMES=$execution_window_times
Environment=IB_GATEWAY_EXECUTION_WINDOW_MINUTES=$execution_window_minutes
Environment=IB_GATEWAY_EXECUTION_WINDOW_TIMEZONE=$execution_window_timezone
Environment=IB_GATEWAY_HEALTHCHECK_FAILURE_THRESHOLD=$failure_threshold
Environment=IB_GATEWAY_HEALTHCHECK_PROBE_TIMEOUT_SECONDS=$probe_timeout_seconds
Environment=IB_GATEWAY_HEALTHCHECK_STATE_FILE=$state_file
ExecStart=/bin/bash -lc 'cd "$repo_dir" && exec ./scripts/monitor_ib_gateway_ready.sh "$gateway_mode"'
EOF

cat >"$systemd_dir/$IBKR_GATEWAY_HEALTHCHECK_TIMER" <<EOF
[Unit]
Description=Wake the adaptive IBKR Gateway API readiness monitor every $healthcheck_tick_seconds seconds

[Timer]
OnActiveSec=$healthcheck_tick_seconds
OnUnitActiveSec=$healthcheck_tick_seconds
Unit=$IBKR_GATEWAY_HEALTHCHECK_SERVICE

[Install]
WantedBy=timers.target
EOF

cat >"$systemd_dir/$IBKR_GATEWAY_DAILY_RESTART_SERVICE" <<EOF
[Unit]
Description=Scheduled IBKR Gateway container restart
After=docker.service network-online.target
Wants=docker.service network-online.target

[Service]
Type=oneshot
WorkingDirectory=$repo_dir
Environment=IB_GATEWAY_CONTAINER_NAME=$container_name
Environment=IB_GATEWAY_COMPOSE_SERVICE_NAME=$compose_service_name
Environment=IB_GATEWAY_MODE=$gateway_mode
Environment=COMPOSE_FILE=$compose_file
Environment=IB_GATEWAY_RECOVERY_LOCK_FILE=$recovery_lock_file
ExecStart=/bin/bash -lc 'cd "$repo_dir" && exec ./scripts/restart_ib_gateway_daily.sh "$gateway_mode"'
EOF

cat >"$systemd_dir/$IBKR_GATEWAY_DAILY_RESTART_TIMER" <<EOF
[Unit]
Description=Restart IBKR Gateway on a fixed daily schedule

[Timer]
OnCalendar=$daily_restart_calendar
Persistent=false
Unit=$IBKR_GATEWAY_DAILY_RESTART_SERVICE

[Install]
WantedBy=timers.target
EOF

"$systemctl_bin" daemon-reload
"$systemctl_bin" enable --now "$IBKR_GATEWAY_HEALTHCHECK_TIMER"
"$systemctl_bin" enable --now "$IBKR_GATEWAY_DAILY_RESTART_TIMER"
