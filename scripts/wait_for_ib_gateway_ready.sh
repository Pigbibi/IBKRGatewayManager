#!/usr/bin/env bash
set -euo pipefail

container_name="${IB_GATEWAY_CONTAINER_NAME:-ib-gateway}"
gateway_mode="${1:-${IB_GATEWAY_MODE:-paper}}"
ready_timeout_seconds="${IB_GATEWAY_READY_TIMEOUT_SECONDS:-240}"
poll_interval_seconds="${IB_GATEWAY_READY_POLL_INTERVAL_SECONDS:-5}"
handshake_timeout_seconds="${IB_GATEWAY_HANDSHAKE_TIMEOUT_SECONDS:-12}"
order_access_timeout_seconds="${IB_GATEWAY_ORDER_ACCESS_TIMEOUT_SECONDS:-4}"
ready_stability_seconds="${IB_GATEWAY_READY_STABILITY_SECONDS:-35}"
configured_healthcheck_client_id="${IB_GATEWAY_HEALTHCHECK_CLIENT_ID:-}"

case "${gateway_mode}" in
  paper)
    gateway_port=4002
    ;;
  live)
    gateway_port=4001
    ;;
  *)
    echo "Unsupported IB gateway mode: ${gateway_mode}" >&2
    exit 1
    ;;
esac

sum_timeout_seconds() {
  awk -v first="$1" -v second="$2" '
    function is_nonnegative_number(value) {
      return value ~ /^([0-9]+([.][0-9]*)?|[.][0-9]+)$/ && value + 0 >= 0
    }

    BEGIN {
      if (!is_nonnegative_number(first) || !is_nonnegative_number(second)) {
        exit 1
      }
      total = first + second
      if (total <= 0) {
        exit 1
      }
      printf "%.15g\n", total
    }
  '
}

if ! process_timeout_seconds="$(
  sum_timeout_seconds "${handshake_timeout_seconds}" "${order_access_timeout_seconds}"
)"; then
  echo "IB Gateway handshake and order-access timeouts must be non-negative numbers with a positive total" >&2
  exit 1
fi

deadline=$((SECONDS + ready_timeout_seconds))

check_api_handshake() {
  local healthcheck_client_id="$1"

  timeout "${process_timeout_seconds}" docker exec -i "${container_name}" \
    env IB_GATEWAY_HEALTHCHECK_PORT="${gateway_port}" \
      IB_GATEWAY_HEALTHCHECK_CLIENT_ID="${healthcheck_client_id}" \
      IB_GATEWAY_HEALTHCHECK_TIMEOUT_SECONDS="${handshake_timeout_seconds}" \
      IB_GATEWAY_ORDER_ACCESS_TIMEOUT_SECONDS="${order_access_timeout_seconds}" \
    python3 <<'PY'
import os
import socket
import struct
import sys
import time


host = "127.0.0.1"
port = int(os.environ["IB_GATEWAY_HEALTHCHECK_PORT"])
client_id = int(os.environ["IB_GATEWAY_HEALTHCHECK_CLIENT_ID"])
timeout_seconds = float(os.environ["IB_GATEWAY_HEALTHCHECK_TIMEOUT_SECONDS"])
order_access_timeout_seconds = float(
    os.environ["IB_GATEWAY_ORDER_ACCESS_TIMEOUT_SECONDS"]
)
deadline = time.monotonic() + timeout_seconds
if client_id <= 0:
    raise RuntimeError("IB API healthcheck client ID must be greater than zero")
read_only_api = os.environ.get("READ_ONLY_API", "").strip().lower()
if read_only_api not in {"yes", "no"}:
    raise RuntimeError(
        "READ_ONLY_API must be explicitly configured as yes or no for the healthcheck"
    )
require_order_access = read_only_api == "no"


try:
    from ib_insync import IB
except ImportError:
    IB = None


if IB is not None:
    ib = IB()
    read_only_errors = []

    def is_read_only_error(message):
        normalized = str(message).lower().replace("-", " ").replace("_", " ")
        return "read only" in " ".join(normalized.split())

    def capture_api_error(_request_id, error_code, error_message, _contract):
        if is_read_only_error(error_message):
            read_only_errors.append((error_code, str(error_message)))

    def request_order_data(label, callback):
        try:
            callback()
        except Exception as exc:
            if read_only_errors or is_read_only_error(exc):
                raise RuntimeError(
                    "IB API writable healthcheck failed: Gateway is in Read-Only mode"
                ) from exc
            raise RuntimeError(
                f"IB API writable healthcheck {label} failed: {type(exc).__name__}"
            ) from exc
        if read_only_errors:
            raise RuntimeError(
                "IB API writable healthcheck failed: Gateway is in Read-Only mode"
            )

    try:
        try:
            ib.connect(
                host,
                port,
                clientId=client_id,
                timeout=timeout_seconds,
                readonly=True,
            )
            accounts = ib.managedAccounts()
            if not accounts:
                raise RuntimeError("IB API healthcheck did not receive managed accounts")
            if require_order_access:
                original_raise_request_errors = ib.RaiseRequestErrors
                original_request_timeout = ib.RequestTimeout
                ib.errorEvent += capture_api_error
                try:
                    # Read order state only; this never calls placeOrder or cancelOrder.
                    ib.RaiseRequestErrors = True
                    ib.RequestTimeout = order_access_timeout_seconds
                    request_order_data("open orders request", ib.reqOpenOrders)
                finally:
                    ib.errorEvent -= capture_api_error
                    ib.RaiseRequestErrors = original_raise_request_errors
                    ib.RequestTimeout = original_request_timeout
                print(
                    "IB API writable healthcheck ready: "
                    f"server_version={ib.client.serverVersion()} "
                    f"client_id={client_id} "
                    f"account_count={len(accounts)}"
                )
            print(
                "IB API ib_insync healthcheck ready: "
                f"server_version={ib.client.serverVersion()} "
                f"client_id={client_id} "
                f"writable={str(require_order_access).lower()} "
                f"account_count={len(accounts)}"
            )
        except Exception as exc:
            print(
                "IB API ib_insync healthcheck not ready: "
                f"{type(exc).__name__}: {exc}",
                file=sys.stderr,
            )
            raise SystemExit(1)
    finally:
        if ib.isConnected():
            ib.disconnect()
    raise SystemExit(0)

if require_order_access:
    print(
        "IB API writable healthcheck requires ib_insync; refusing raw handshake fallback",
        file=sys.stderr,
    )
    raise SystemExit(1)


def remaining_timeout() -> float:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError("IB API healthcheck timed out")
    return remaining


def recv_exact(sock: socket.socket, size: int) -> bytes:
    chunks = []
    remaining = size
    while remaining > 0:
        sock.settimeout(remaining_timeout())
        chunk = sock.recv(remaining)
        if not chunk:
            raise ConnectionError("IB API socket closed during healthcheck")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def read_fields(sock: socket.socket) -> list[str]:
    raw_size = recv_exact(sock, 4)
    size = struct.unpack(">I", raw_size)[0]
    payload = recv_exact(sock, size).decode(errors="backslashreplace")
    fields = payload.split("\0")
    if fields and fields[-1] == "":
        fields.pop()
    return fields


def send_prefixed(sock: socket.socket, payload: bytes) -> None:
    sock.sendall(struct.pack(">I", len(payload)) + payload)


with socket.create_connection((host, port), timeout=remaining_timeout()) as sock:
    sock.settimeout(remaining_timeout())
    # Match the modern IB API v100+ handshake used by ib_insync.
    hello = b"API\0" + struct.pack(">I", len(b"v157..176")) + b"v157..176"
    sock.sendall(hello)

    handshake_fields = read_fields(sock)
    if len(handshake_fields) != 2:
        raise RuntimeError(f"unexpected IB handshake response: {handshake_fields!r}")
    server_version = int(handshake_fields[0])
    if server_version < 157:
        raise RuntimeError(f"IB server version too old for healthcheck: {server_version}")

    start_api_payload = b"71\0" + b"2\0" + str(client_id).encode() + b"\0\0"
    send_prefixed(sock, start_api_payload)

    has_next_valid_id = False
    has_managed_accounts = False
    while not (has_next_valid_id and has_managed_accounts):
        fields = read_fields(sock)
        if not fields:
            continue
        msg_id = fields[0]
        if msg_id == "9":
            has_next_valid_id = True
        elif msg_id == "15":
            has_managed_accounts = True

print(f"IB API handshake ready: server_version={server_version} client_id={client_id}")
PY
}

next_healthcheck_client_id() {
  if [ -n "${configured_healthcheck_client_id}" ]; then
    echo "${configured_healthcheck_client_id}"
  else
    echo $((9000 + ((BASHPID + SECONDS + RANDOM) % 9000)))
  fi
}

confirm_stable_ready() {
  local stability_seconds="$1"
  local stable_deadline=$((SECONDS + stability_seconds))
  local healthcheck_client_id

  if [ "${stability_seconds}" -le 0 ]; then
    return 0
  fi

  echo "IB gateway API handshake succeeded; confirming stability for ${stability_seconds}s"
  while [ "${SECONDS}" -lt "${stable_deadline}" ]; do
    sleep "${poll_interval_seconds}"
    if ! docker inspect --format '{{.State.Running}}' "${container_name}" 2>/dev/null | grep -Fxq 'true'; then
      echo "IB gateway container stopped during readiness stability window" >&2
      return 1
    fi
    healthcheck_client_id="$(next_healthcheck_client_id)"
    if ! check_api_handshake "${healthcheck_client_id}"; then
      echo "IB gateway API readiness was not stable during confirmation window" >&2
      return 1
    fi
  done
}

echo "Waiting for ${container_name} IB API handshake readiness on internal port ${gateway_port} (mode=${gateway_mode}, client_id=${configured_healthcheck_client_id:-auto})"

while true; do
  if docker inspect --format '{{.State.Running}}' "${container_name}" 2>/dev/null | grep -Fxq 'true'; then
    healthcheck_client_id="$(next_healthcheck_client_id)"
    if check_api_handshake "${healthcheck_client_id}" && confirm_stable_ready "${ready_stability_seconds}"; then
      echo "IB gateway API handshake is ready on internal port ${gateway_port} (mode=${gateway_mode})"
      exit 0
    fi
  fi

  if [ "${SECONDS}" -ge "${deadline}" ]; then
    echo "Timed out waiting for ${container_name} IB API handshake readiness on internal port ${gateway_port}" >&2
    echo "--- docker compose ps ---" >&2
    docker compose ps >&2 || true
    echo "--- recent container logs ---" >&2
    docker logs --tail 120 "${container_name}" >&2 || true
    exit 1
  fi

  sleep "${poll_interval_seconds}"
done
