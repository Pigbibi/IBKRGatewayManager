#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

mkdir -p "$tmpdir/bin" "$tmpdir/systemd"
systemctl_log="$tmpdir/systemctl.log"
fake_systemctl="$tmpdir/fake-systemctl"

cat >"$fake_systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
EOF
chmod +x "$fake_systemctl"

SYSTEMCTL_LOG="$systemctl_log" \
SYSTEMCTL_BIN="$fake_systemctl" \
BIN_DIR="$tmpdir/bin" \
SYSTEMD_DIR="$tmpdir/systemd" \
CONTAINER_NAME="ib-gateway-test" \
bash "$repo_dir/scripts/install_2fa_bot_watcher.sh"

test -x "$tmpdir/bin/ensure-ibkr-2fa-bot-running"
grep -Fq 'Environment=CONTAINER_NAME=ib-gateway-test' "$tmpdir/systemd/ibkr-2fa-bot.service"
grep -Fq 'ExecStart='"$tmpdir"'/bin/ensure-ibkr-2fa-bot-running' "$tmpdir/systemd/ibkr-2fa-bot.service"
grep -Fq 'OnUnitActiveSec=1min' "$tmpdir/systemd/ibkr-2fa-bot.timer"
grep -Fq 'enable --now ibkr-2fa-bot.timer' "$systemctl_log"
grep -Fq 'start ibkr-2fa-bot.service' "$systemctl_log"
