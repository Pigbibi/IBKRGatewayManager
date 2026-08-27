#!/usr/bin/env bash
set -euo pipefail

# Return zero only when an unacknowledged compact Gateway dialog is currently
# visible.  The probe is intentionally live-window based: a historical error
# line must not suppress recovery after an operator has cleared the dialog.
container_name="${IB_GATEWAY_CONTAINER_NAME:-ib-gateway}"

if ! docker inspect --format '{{.State.Running}}' "${container_name}" 2>/dev/null | grep -Fxq 'true'; then
  exit 1
fi

docker exec "${container_name}" \
  python3 /home/ibgateway/2fa_bot.py --check-gateway-ui-blocker >/dev/null
