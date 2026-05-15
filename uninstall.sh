#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
Usage:
  ./uninstall.sh

Removes scheduled jobs created by install.sh.
It does not delete config, logs, source files, or NAS snapshots.
EOF
}

remove_systemd() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user disable --now backup-agent.timer >/dev/null 2>&1 || true
    rm -f "$HOME/.config/systemd/user/backup-agent.timer"
    rm -f "$HOME/.config/systemd/user/backup-agent.service"
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    printf 'Removed systemd user timer/service if present.\n'
  fi
}

remove_cron() {
  local tmp marker
  marker="# backup-agent:$SCRIPT_DIR"
  tmp="$(mktemp)"
  crontab -l 2>/dev/null | grep -vF "$marker" > "$tmp" || true
  crontab "$tmp" 2>/dev/null || true
  rm -f "$tmp"
  printf 'Removed cron entry if present.\n'
}

remove_launchd() {
  local machine label plist
  machine="$(hostname -s 2>/dev/null || hostname)"
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    machine="${MACHINE_NAME:-$machine}"
  fi
  label="com.backup-agent.$machine"
  plist="$HOME/Library/LaunchAgents/$label.plist"
  if [[ -f "$plist" ]]; then
    launchctl unload "$plist" >/dev/null 2>&1 || true
    rm -f "$plist"
  fi
  printf 'Removed launchd LaunchAgent if present.\n'
}

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
  '') ;;
  *) usage; exit 2 ;;
esac

remove_systemd
remove_cron
if [[ "$(uname -s)" == "Darwin" ]]; then
  remove_launchd
fi

cat <<EOF
Uninstall complete.

Left in place:
  $CONFIG_FILE
  $LOG_DIR
  NAS snapshots
EOF

