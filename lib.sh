#!/usr/bin/env bash

# Shared helpers for backup-agent scripts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${BACKUP_AGENT_CONFIG:-$SCRIPT_DIR/config}"
LOG_DIR="$SCRIPT_DIR/logs"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'WARN: %s\n' "$*" >&2
}

info() {
  printf '%s\n' "$*"
}

truthy() {
  case "${1:-}" in
    1|yes|true|on|Y|YES|TRUE|ON) return 0 ;;
    *) return 1 ;;
  esac
}

shell_quote() {
  # Bash printf %q is available on macOS Bash 3.2 and keeps remote commands readable.
  printf '%q' "$1"
}

single_quote() {
  # Quote for command strings consumed by tools such as rsync -e.
  printf "'%s'" "${1//\'/\'\\\'\'}"
}

expand_path() {
  local path="${1:-}"
  if [[ "$path" == "~" ]]; then
    printf '%s\n' "$HOME"
  elif [[ "$path" == "~/"* ]]; then
    printf '%s/%s\n' "$HOME" "${path#~/}"
  else
    printf '%s\n' "$path"
  fi
}

load_config() {
  [[ -f "$CONFIG_FILE" ]] || die "Config file not found: $CONFIG_FILE. Copy config.example to config first."
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"

  MACHINE_NAME="${MACHINE_NAME:-$(hostname -s 2>/dev/null || hostname)}"
  BACKUP_TARGET="${BACKUP_TARGET:-}"
  SNAPSHOT_ROOT="${SNAPSHOT_ROOT:-${BACKUP_TARGET%/}/$MACHINE_NAME}"
  BACKUP_FREQUENCY="${BACKUP_FREQUENCY:-hourly}"
  BACKUP_TIMEZONE="${BACKUP_TIMEZONE:-}"
  SSH_PORT="${SSH_PORT:-}"
  SSH_KEY="${SSH_KEY:-}"
  if [[ -n "$SSH_KEY" ]]; then
    SSH_KEY="$(expand_path "$SSH_KEY")"
  fi
  if [[ -z "${SSH_EXTRA_OPTS+x}" ]]; then
    SSH_EXTRA_OPTS=()
  fi
  MIN_FREE_SPACE_GB="${MIN_FREE_SPACE_GB:-0}"
  MAX_SOURCE_SIZE_GB="${MAX_SOURCE_SIZE_GB:-500}"
  DRY_RUN_BY_DEFAULT="${DRY_RUN_BY_DEFAULT:-true}"
  ONE_FILE_SYSTEM="${ONE_FILE_SYSTEM:-true}"
  CLEAN_STALE_INCOMPLETE="${CLEAN_STALE_INCOMPLETE:-true}"
  ALLOW_RSYNC_PARTIAL="${ALLOW_RSYNC_PARTIAL:-true}"
  PRUNE_AFTER_BACKUP="${PRUNE_AFTER_BACKUP:-false}"
  RETENTION_KEEP_RECENT="${RETENTION_KEEP_RECENT:-0}"
  RETENTION_HOURLY="${RETENTION_HOURLY:-24}"
  RETENTION_DAILY="${RETENTION_DAILY:-14}"
  RETENTION_WEEKLY="${RETENTION_WEEKLY:-8}"
  RETENTION_MONTHLY="${RETENTION_MONTHLY:-12}"
  VERBOSE="${VERBOSE:-false}"

  [[ -n "$BACKUP_TARGET" ]] || die "BACKUP_TARGET is empty in config."
  [[ -n "$SNAPSHOT_ROOT" ]] || die "SNAPSHOT_ROOT is empty in config."
  if [[ -z "${SOURCE_PATHS+x}" || "${#SOURCE_PATHS[@]}" -eq 0 ]]; then
    die "SOURCE_PATHS is empty in config."
  fi
}

source_size_kb() {
  local path="$1" output value
  if [[ -d "$path" ]] && truthy "$ONE_FILE_SYSTEM"; then
    output="$(du -sk -x "$path" 2>/dev/null || true)"
  else
    output="$(du -sk "$path" 2>/dev/null || true)"
  fi
  value="$(printf '%s\n' "$output" | awk 'NR==1 {print $1}')"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$value"
  else
    return 1
  fi
}
TARGET_MODE=""
REMOTE_HOST=""
REMOTE_PATH=""
LOCAL_ROOT=""

parse_snapshot_root() {
  local root="${SNAPSHOT_ROOT%/}"
  TARGET_MODE=""
  REMOTE_HOST=""
  REMOTE_PATH=""
  LOCAL_ROOT=""

  if [[ "$root" == rsync://* ]]; then
    TARGET_MODE="rsync_daemon"
    REMOTE_PATH="$root"
  elif [[ "$root" == *:* && "$root" != /* ]]; then
    TARGET_MODE="ssh"
    REMOTE_HOST="${root%%:*}"
    REMOTE_PATH="${root#*:}"
    [[ -n "$REMOTE_HOST" && -n "$REMOTE_PATH" ]] || die "Could not parse SNAPSHOT_ROOT: $SNAPSHOT_ROOT"
  else
    TARGET_MODE="local"
    LOCAL_ROOT="$(expand_path "$root")"
  fi
}

require_managed_target() {
  if [[ "$TARGET_MODE" == "rsync_daemon" ]]; then
    die "rsync:// targets do not provide remote rename, hard-link validation, latest updates, or safe pruning. Use an SSH-style target such as user@nas:/volume/backups/$MACHINE_NAME for full snapshot mode."
  fi
}

target_display_root() {
  case "$TARGET_MODE" in
    ssh) printf '%s:%s\n' "$REMOTE_HOST" "$REMOTE_PATH" ;;
    local) printf '%s\n' "$LOCAL_ROOT" ;;
    rsync_daemon) printf '%s\n' "$REMOTE_PATH" ;;
    *) printf '%s\n' "$SNAPSHOT_ROOT" ;;
  esac
}

remote_exec() {
  [[ "$TARGET_MODE" == "ssh" ]] || die "remote_exec called for non-ssh target"
  local ssh_cmd=(ssh)
  [[ -n "${SSH_PORT:-}" ]] && ssh_cmd+=(-p "$SSH_PORT")
  [[ -n "${SSH_KEY:-}" ]] && ssh_cmd+=(-i "$SSH_KEY")
  ssh_cmd+=("${SSH_EXTRA_OPTS[@]}")
  "${ssh_cmd[@]}" "$REMOTE_HOST" "$@"
}

rsync_ssh_args() {
  [[ "$TARGET_MODE" == "ssh" ]] || return 0
  local rsh="ssh"
  [[ -n "${SSH_PORT:-}" ]] && rsh="$rsh -p $(single_quote "$SSH_PORT")"
  [[ -n "${SSH_KEY:-}" ]] && rsh="$rsh -i $(single_quote "$SSH_KEY")"
  local opt
  for opt in "${SSH_EXTRA_OPTS[@]}"; do
    rsh="$rsh $(single_quote "$opt")"
  done
  printf '%s\n' "$rsh"
}

target_mkdirs() {
  case "$TARGET_MODE" in
    ssh)
      remote_exec "mkdir -p $(shell_quote "$REMOTE_PATH")/snapshots"
      ;;
    local)
      mkdir -p "$LOCAL_ROOT/snapshots"
      ;;
    rsync_daemon)
      die "Cannot create managed snapshot directories on rsync:// target."
      ;;
  esac
}

target_rsync_path() {
  local rel="${1#/}"
  case "$TARGET_MODE" in
    ssh) printf '%s:%s/%s\n' "$REMOTE_HOST" "${REMOTE_PATH%/}" "$rel" ;;
    local) printf '%s/%s\n' "${LOCAL_ROOT%/}" "$rel" ;;
    rsync_daemon) printf '%s/%s\n' "${REMOTE_PATH%/}" "$rel" ;;
  esac
}

list_snapshots() {
  case "$TARGET_MODE" in
    ssh)
      remote_exec "test -d $(shell_quote "$REMOTE_PATH")/snapshots && find $(shell_quote "$REMOTE_PATH")/snapshots -mindepth 1 -maxdepth 1 -type d -exec basename {} \\; | sort || true"
      ;;
    local)
      [[ -d "$LOCAL_ROOT/snapshots" ]] && find "$LOCAL_ROOT/snapshots" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort || true
      ;;
    rsync_daemon)
      rsync "${REMOTE_PATH%/}/snapshots/" 2>/dev/null | awk '{print $NF}' | sort || true
      ;;
  esac
}

list_incomplete_snapshots() {
  case "$TARGET_MODE" in
    ssh)
      remote_exec "test -d $(shell_quote "$REMOTE_PATH") && find $(shell_quote "$REMOTE_PATH") -mindepth 1 -maxdepth 1 -type d -name '.incomplete-*' -exec basename {} \\; | sort || true"
      ;;
    local)
      [[ -d "$LOCAL_ROOT" ]] && find "$LOCAL_ROOT" -mindepth 1 -maxdepth 1 -type d -name '.incomplete-*' -exec basename {} \; | sort || true
      ;;
    rsync_daemon)
      die "Cannot safely list incomplete snapshots on rsync:// target."
      ;;
  esac
}

latest_snapshot_name() {
  local target
  case "$TARGET_MODE" in
    ssh)
      target="$(remote_exec "if [ -L $(shell_quote "$REMOTE_PATH")/latest ]; then readlink $(shell_quote "$REMOTE_PATH")/latest; fi" 2>/dev/null || true)"
      ;;
    local)
      target="$([[ -L "$LOCAL_ROOT/latest" ]] && readlink "$LOCAL_ROOT/latest" || true)"
      ;;
    rsync_daemon)
      target=""
      ;;
  esac
  target="${target%/}"
  printf '%s\n' "${target##*/}"
}

safe_snapshot_name() {
  [[ "${1:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]]
}

safe_rel_name() {
  [[ -n "${1:-}" && "$1" != "." && "$1" != ".." && "$1" != */* ]]
}

safe_root_or_die() {
  local root
  root="$(target_display_root)"
  [[ -n "$root" ]] || die "Refusing to operate on empty snapshot root."
  [[ "$root" != "/" ]] || die "Refusing to operate on /."
  [[ "$root" != "." && "$root" != ".." ]] || die "Refusing to operate on malformed snapshot root: $root"
  [[ "$root" == *"$MACHINE_NAME"* ]] || warn "SNAPSHOT_ROOT does not contain MACHINE_NAME; verify namespace is intentional: $root"
}

delete_remote_tree() {
  local rel="$1"
  [[ -n "$rel" && "$rel" != "/" && "$rel" != "." && "$rel" != ".." ]] || die "Refusing unsafe delete path: $rel"
  case "$TARGET_MODE" in
    ssh)
      remote_exec "rm -rf -- $(shell_quote "$REMOTE_PATH/$rel")"
      ;;
    local)
      rm -rf -- "$LOCAL_ROOT/$rel"
      ;;
    rsync_daemon)
      die "Cannot safely delete managed snapshots on rsync:// target."
      ;;
  esac
}

snapshot_exists() {
  local snap="$1"
  case "$TARGET_MODE" in
    ssh) remote_exec "test -d $(shell_quote "$REMOTE_PATH/snapshots/$snap")" >/dev/null 2>&1 ;;
    local) [[ -d "$LOCAL_ROOT/snapshots/$snap" ]] ;;
    rsync_daemon) return 1 ;;
  esac
}

update_latest() {
  local snap="$1"
  safe_snapshot_name "$snap" || die "Refusing malformed snapshot name: $snap"
  case "$TARGET_MODE" in
    ssh)
      remote_exec "cd $(shell_quote "$REMOTE_PATH") && ln -sfn $(shell_quote "snapshots/$snap") latest"
      ;;
    local)
      (cd "$LOCAL_ROOT" && ln -sfn "snapshots/$snap" latest)
      ;;
    rsync_daemon)
      die "Cannot update latest on rsync:// target."
      ;;
  esac
}

rename_incomplete_snapshot() {
  local tmp="$1"
  local snap="$2"
  safe_rel_name "$tmp" || die "Refusing malformed temp snapshot name: $tmp"
  safe_snapshot_name "$snap" || die "Refusing malformed snapshot name: $snap"
  case "$TARGET_MODE" in
    ssh)
      remote_exec "mv $(shell_quote "$REMOTE_PATH/$tmp") $(shell_quote "$REMOTE_PATH/snapshots/$snap")"
      ;;
    local)
      mv "$LOCAL_ROOT/$tmp" "$LOCAL_ROOT/snapshots/$snap"
      ;;
    rsync_daemon)
      die "Cannot atomically rename snapshots on rsync:// target."
      ;;
  esac
}

available_gb() {
  case "$TARGET_MODE" in
    ssh)
      remote_exec "df -Pk $(shell_quote "$REMOTE_PATH") | awk 'NR==2 {printf \"%d\\n\", \$4/1024/1024}'"
      ;;
    local)
      df -Pk "$LOCAL_ROOT" | awk 'NR==2 {printf "%d\n", $4/1024/1024}'
      ;;
    rsync_daemon)
      printf '0\n'
      ;;
  esac
}

timestamp() {
  if [[ -n "${BACKUP_TIMEZONE:-}" ]]; then
    TZ="$BACKUP_TIMEZONE" date '+%Y-%m-%d_%H-%M-%S'
  else
    date '+%Y-%m-%d_%H-%M-%S'
  fi
}

setup_log() {
  mkdir -p "$LOG_DIR"
  local stamp="$1"
  LOG_FILE="$LOG_DIR/backup-$stamp.log"
  touch "$LOG_FILE"
  ln -sf "$(basename "$LOG_FILE")" "$LOG_DIR/latest.log"
  export LOG_FILE
}

log() {
  local line
  line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  printf '%s\n' "$line"
  if [[ -n "${LOG_FILE:-}" ]]; then
    printf '%s\n' "$line" >> "$LOG_FILE"
  fi
}
