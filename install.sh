#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
Usage:
  ./install.sh [systemd|cron|launchd]

Default scheduler:
  Linux: systemd user timer if available, otherwise cron
  macOS: launchd LaunchAgent

Run this from the backup-agent directory after editing config.
EOF
}

ensure_config() {
  mkdir -p "$LOG_DIR"
  if [[ ! -f "$CONFIG_FILE" ]]; then
    cp "$SCRIPT_DIR/config.example" "$CONFIG_FILE"
    cat <<EOF
Created config: $CONFIG_FILE

Edit it before installing the scheduled job:
  $CONFIG_FILE

Then run:
  ./validate.sh
  ./backup.sh dry-run
  ./install.sh
EOF
    exit 0
  fi
}

ensure_rsync() {
  if command -v rsync >/dev/null 2>&1; then
    return
  fi

  case "$(uname -s)" in
    Linux)
      if command -v apt-get >/dev/null 2>&1; then
        printf 'rsync is missing. Install with apt now? [y/N] '
        read -r answer
        case "$answer" in
          y|Y|yes|YES)
            sudo apt-get update
            sudo apt-get install -y rsync
            ;;
          *) die "Install rsync, then rerun ./install.sh." ;;
        esac
      else
        die "rsync is missing. Install it with your package manager, then rerun ./install.sh."
      fi
      ;;
    Darwin)
      die "rsync is missing. macOS usually includes rsync; Homebrew rsync is optional but not required."
      ;;
    *)
      die "rsync is missing. Install it, then rerun ./install.sh."
      ;;
  esac
}

systemd_calendar() {
  case "$BACKUP_FREQUENCY" in
    hourly) printf 'hourly\n' ;;
    daily) printf 'daily\n' ;;
    weekly) printf 'weekly\n' ;;
    *) printf '%s\n' "$BACKUP_FREQUENCY" ;;
  esac
}

cron_schedule() {
  case "$BACKUP_FREQUENCY" in
    hourly) printf '0 * * * *\n' ;;
    daily) printf '0 3 * * *\n' ;;
    weekly) printf '0 3 * * 0\n' ;;
    *) printf '%s\n' "$BACKUP_FREQUENCY" ;;
  esac
}

launchd_interval() {
  case "$BACKUP_FREQUENCY" in
    hourly) printf '3600\n' ;;
    daily) printf '86400\n' ;;
    weekly) printf '604800\n' ;;
    ''|*) printf '3600\n' ;;
  esac
}

install_systemd() {
  command -v systemctl >/dev/null 2>&1 || die "systemctl not found; use ./install.sh cron."

  local user_dir service timer calendar
  user_dir="$HOME/.config/systemd/user"
  service="$user_dir/backup-agent.service"
  timer="$user_dir/backup-agent.timer"
  calendar="$(systemd_calendar)"
  mkdir -p "$user_dir"

  cat > "$service" <<EOF
[Unit]
Description=backup-agent rsync snapshot backup

[Service]
Type=oneshot
WorkingDirectory=$SCRIPT_DIR
ExecStart=/usr/bin/env bash $SCRIPT_DIR/backup.sh run
EOF

  cat > "$timer" <<EOF
[Unit]
Description=Run backup-agent on schedule

[Timer]
OnCalendar=$calendar
Persistent=true
Unit=backup-agent.service

[Install]
WantedBy=timers.target
EOF

  systemctl --user daemon-reload
  systemctl --user enable --now backup-agent.timer

  cat <<EOF
Installed systemd user timer:
  $timer

Status:
  systemctl --user list-timers backup-agent.timer

systemd Persistent=true can catch up missed runs after the user session is available.
EOF
}

install_cron() {
  local schedule tmp marker job
  schedule="$(cron_schedule)"
  marker="# backup-agent:$SCRIPT_DIR"
  job="$schedule cd $SCRIPT_DIR && /usr/bin/env bash ./backup.sh run >> $LOG_DIR/cron.log 2>&1 $marker"
  tmp="$(mktemp)"

  crontab -l 2>/dev/null | grep -vF "$marker" > "$tmp" || true
  printf '%s\n' "$job" >> "$tmp"
  crontab "$tmp"
  rm -f "$tmp"

  cat <<EOF
Installed cron job:
  $job

Note: cron jobs do not run while the machine is off or asleep.
EOF
}

install_launchd() {
  local plist label interval
  label="com.backup-agent.$MACHINE_NAME"
  plist="$HOME/Library/LaunchAgents/$label.plist"
  interval="$(launchd_interval)"
  mkdir -p "$HOME/Library/LaunchAgents"

  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$SCRIPT_DIR/backup.sh</string>
    <string>run</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$SCRIPT_DIR</string>
  <key>StartInterval</key>
  <integer>$interval</integer>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/launchd.out.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/launchd.err.log</string>
</dict>
</plist>
EOF

  launchctl unload "$plist" >/dev/null 2>&1 || true
  launchctl load "$plist"

  cat <<EOF
Installed launchd LaunchAgent:
  $plist

The job runs when the Mac is awake. Do not assume a closed sleeping MacBook wakes up for backups.
EOF
}

main() {
  case "${1:-}" in
    -h|--help|help) usage; exit 0 ;;
  esac

  ensure_config
  load_config
  parse_snapshot_root
  ensure_rsync

  "$SCRIPT_DIR/validate.sh"

  local scheduler="${1:-}"
  if [[ -z "$scheduler" ]]; then
    case "$(uname -s)" in
      Darwin) scheduler="launchd" ;;
      Linux)
        if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
          scheduler="systemd"
        else
          scheduler="cron"
        fi
        ;;
      *) scheduler="cron" ;;
    esac
  fi

  case "$scheduler" in
    systemd) install_systemd ;;
    cron) install_cron ;;
    launchd) install_launchd ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"

