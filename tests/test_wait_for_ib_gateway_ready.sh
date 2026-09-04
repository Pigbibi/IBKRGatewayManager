#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
script_file="$repo_dir/scripts/wait_for_ib_gateway_ready.sh"
recovery_script="$repo_dir/scripts/recover_ib_gateway_ready.sh"
daily_restart_script="$repo_dir/scripts/restart_ib_gateway_daily.sh"
blocker_probe_script="$repo_dir/scripts/detect_gateway_ui_blocker.sh"

test -f "$script_file"
test -x "$script_file" || true
grep -Fq 'container_name="${IB_GATEWAY_CONTAINER_NAME:-ib-gateway}"' "$script_file"
grep -Fq 'ready_timeout_seconds="${IB_GATEWAY_READY_TIMEOUT_SECONDS:-240}"' "$script_file"
grep -Fq 'ready_stability_seconds="${IB_GATEWAY_READY_STABILITY_SECONDS:-35}"' "$script_file"
grep -Fq 'order_access_timeout_seconds="${IB_GATEWAY_ORDER_ACCESS_TIMEOUT_SECONDS:-4}"' "$script_file"
grep -Fq 'gateway_port=4002' "$script_file"
grep -Fq 'gateway_port=4001' "$script_file"
grep -Fq "docker inspect --format '{{.State.Running}}'" "$script_file"
grep -Fq 'configured_healthcheck_client_id="${IB_GATEWAY_HEALTHCHECK_CLIENT_ID:-}"' "$script_file"
grep -Fq 'next_healthcheck_client_id()' "$script_file"
grep -Fq 'RANDOM) % 9000' "$script_file"
grep -Fq 'check_api_handshake()' "$script_file"
grep -Fq 'confirm_stable_ready()' "$script_file"
grep -Fq 'confirming stability' "$script_file"
grep -Fq 'from ib_insync import IB' "$script_file"
grep -Fq 'readonly=True' "$script_file"
grep -Fq 'read_only_api = os.environ.get("READ_ONLY_API", "").strip().lower()' "$script_file"
grep -Fq 'require_order_access = read_only_api == "no"' "$script_file"
grep -Fq 'ib.RaiseRequestErrors = True' "$script_file"
grep -Fq 'ib.RequestTimeout = order_access_timeout_seconds' "$script_file"
grep -Fq 'request_order_data("open orders request", ib.reqOpenOrders)' "$script_file"
if grep -Fq 'ib.reqCompletedOrders(' "$script_file"; then
  echo "Gateway readiness must not depend on completed-order history" >&2
  exit 1
fi
grep -Fq 'if client_id <= 0:' "$script_file"
grep -Fq 'IB API writable healthcheck ready' "$script_file"
grep -Fq 'account_count={len(accounts)}' "$script_file"
if grep -Fq "accounts={','.join(accounts)}" "$script_file"; then
  echo "Gateway healthcheck must not log account identifiers" >&2
  exit 1
fi
grep -Fq 'IB API ib_insync healthcheck ready' "$script_file"
grep -Fq 'b"API\0" + struct.pack(">I", len(b"v157..176")) + b"v157..176"' "$script_file"
grep -Fq 'has_next_valid_id and has_managed_accounts' "$script_file"
grep -Fq 'IB API handshake readiness' "$script_file"
grep -Fq 'docker logs --tail 120 "${container_name}"' "$script_file"
test -x "$blocker_probe_script"
grep -Fq -- '--check-gateway-ui-blocker' "$blocker_probe_script"
grep -Fq 'gateway_ui_blocker_present()' "$recovery_script"
grep -Fq 'fail_recovery "GATEWAY_UI_BLOCKER" 3' "$recovery_script"
grep -Fq 'if gateway_ui_blocker_present; then' "$recovery_script"
grep -Fq 'continuing with the scheduled no-click restart' "$daily_restart_script"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
awk '
  /^sum_timeout_seconds\(\) \{/ { capture = 1 }
  capture { print }
  capture && /^}/ { exit }
' "$script_file" > "$tmp_dir/sum_timeout_seconds.sh"
# shellcheck disable=SC1091
source "$tmp_dir/sum_timeout_seconds.sh"
test "$(sum_timeout_seconds 12 0.5)" = "12.5"
if sum_timeout_seconds invalid 0.5 >/dev/null 2>&1; then
  echo "Invalid Gateway timeout unexpectedly passed validation" >&2
  exit 1
fi

awk '
  /^[[:space:]]*python3 <<'\''PY'\''$/ { capture = 1; next }
  capture && /^PY$/ { exit }
  capture { print }
' "$script_file" > "$tmp_dir/check_api.py"
cat > "$tmp_dir/ib_insync.py" <<'PY'
import os


class Event:
    def __init__(self):
        self.handlers = []

    def __iadd__(self, handler):
        self.handlers.append(handler)
        return self

    def __isub__(self, handler):
        self.handlers.remove(handler)
        return self

    def emit(self, *args):
        for handler in tuple(self.handlers):
            handler(*args)


class Client:
    @staticmethod
    def serverVersion():
        return 176


class IB:
    RaiseRequestErrors = False
    RequestTimeout = 0

    def __init__(self):
        self.client = Client()
        self.errorEvent = Event()
        self.connected = False

    def connect(self, *_args, **kwargs):
        assert kwargs["clientId"] > 0
        assert kwargs["readonly"] is True
        self.connected = True

    @staticmethod
    def managedAccounts():
        return ["U_TEST"]

    def reqOpenOrders(self):
        assert self.RaiseRequestErrors is True
        assert self.RequestTimeout == 1
        if os.environ.get("FAKE_IB_READ_ONLY") == "1":
            self.errorEvent.emit(-1, 321, "API is in Read-Only mode", None)
            raise TimeoutError("open orders timed out")
        if os.environ.get("FAKE_IB_UNRELATED_321") == "1":
            self.errorEvent.emit(-1, 321, "Generic validation error", None)
        if os.environ.get("FAKE_IB_FAIL_ON_ORDER_ACCESS") == "1":
            raise AssertionError("order access probe must not run")
        return []

    def reqCompletedOrders(self, *, apiOnly):
        assert apiOnly is True
        return []

    def isConnected(self):
        return self.connected

    def disconnect(self):
        self.connected = False
PY

healthcheck_env=(
  IB_GATEWAY_HEALTHCHECK_PORT=4001
  IB_GATEWAY_HEALTHCHECK_CLIENT_ID=9001
  IB_GATEWAY_HEALTHCHECK_TIMEOUT_SECONDS=2
  IB_GATEWAY_ORDER_ACCESS_TIMEOUT_SECONDS=1
  PYTHONPATH="$tmp_dir"
)

env "${healthcheck_env[@]}" READ_ONLY_API=no \
  python3 "$tmp_dir/check_api.py" > "$tmp_dir/writable.out"
grep -Fq 'IB API writable healthcheck ready' "$tmp_dir/writable.out"
grep -Fq 'account_count=1' "$tmp_dir/writable.out"

if env "${healthcheck_env[@]}" READ_ONLY_API=no FAKE_IB_READ_ONLY=1 \
  python3 "$tmp_dir/check_api.py" > "$tmp_dir/read-only.out" 2>&1; then
  echo "Read-Only Gateway unexpectedly passed writable healthcheck" >&2
  exit 1
fi
grep -Fq 'Gateway is in Read-Only mode' "$tmp_dir/read-only.out"

env "${healthcheck_env[@]}" READ_ONLY_API=no FAKE_IB_UNRELATED_321=1 \
  python3 "$tmp_dir/check_api.py" > "$tmp_dir/unrelated-321.out"
grep -Fq 'IB API writable healthcheck ready' "$tmp_dir/unrelated-321.out"

env "${healthcheck_env[@]}" READ_ONLY_API=yes FAKE_IB_FAIL_ON_ORDER_ACCESS=1 \
  python3 "$tmp_dir/check_api.py" > "$tmp_dir/read-only-expected.out"
grep -Fq 'writable=false' "$tmp_dir/read-only-expected.out"

if env "${healthcheck_env[@]}" IB_GATEWAY_HEALTHCHECK_CLIENT_ID=0 READ_ONLY_API=no \
  python3 "$tmp_dir/check_api.py" > "$tmp_dir/client-zero.out" 2>&1; then
  echo "clientId=0 unexpectedly passed Gateway healthcheck" >&2
  exit 1
fi
grep -Fq 'client ID must be greater than zero' "$tmp_dir/client-zero.out"
