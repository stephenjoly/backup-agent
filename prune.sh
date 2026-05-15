#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
Usage:
  ./prune.sh dry-run
  ./prune.sh run
  ./prune.sh list

Pruning deletes old snapshot directories on the destination. Always run dry-run first.
EOF
}

setup_prune_log() {
  mkdir -p "$LOG_DIR"
  local stamp="$1"
  LOG_FILE="$LOG_DIR/prune-$stamp.log"
  touch "$LOG_FILE"
  ln -sf "$(basename "$LOG_FILE")" "$LOG_DIR/latest.log"
  export LOG_FILE
}

date_supports_gnu=false
if date -d '1970-01-01 00:00:00' '+%s' >/dev/null 2>&1; then
  date_supports_gnu=true
fi

snapshot_epoch() {
  local snap="$1"
  local gnu_value="${snap:0:10} ${snap:11:2}:${snap:14:2}:${snap:17:2}"
  if [[ "$date_supports_gnu" == true ]]; then
    date -d "$gnu_value" '+%s'
  else
    date -j -f '%Y-%m-%d_%H-%M-%S' "$snap" '+%s'
  fi
}

snapshot_fmt() {
  local snap="$1"
  local fmt="$2"
  local gnu_value="${snap:0:10} ${snap:11:2}:${snap:14:2}:${snap:17:2}"
  if [[ "$date_supports_gnu" == true ]]; then
    date -d "$gnu_value" "$fmt"
  else
    date -j -f '%Y-%m-%d_%H-%M-%S' "$snap" "$fmt"
  fi
}

contains_line() {
  local haystack="$1"
  local needle="$2"
  printf '%s\n' "$haystack" | grep -qx -- "$needle"
}

add_line_once() {
  local current="$1"
  local value="$2"
  if contains_line "$current" "$value"; then
    printf '%s' "$current"
  elif [[ -z "$current" ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n%s\n' "$current" "$value"
  fi
}

choose_snapshots_to_keep() {
  local latest="$1"
  local now_epoch="$2"
  local keep="" daily_buckets="" weekly_buckets="" monthly_buckets=""
  local idx=0 snap epoch age bucket

  for snap in "${SNAPSHOTS_DESC[@]}"; do
    idx=$((idx + 1))

    if ! safe_snapshot_name "$snap"; then
      log "KEEP malformed/unexpected snapshot name for manual review: $snap"
      keep="$(add_line_once "$keep" "$snap")"
      continue
    fi

    if [[ "$snap" == "$latest" || "$idx" -eq 1 ]]; then
      log "KEEP $snap (latest/newest)"
      keep="$(add_line_once "$keep" "$snap")"
      continue
    fi

    if [[ "${RETENTION_KEEP_RECENT:-0}" -gt 0 ]]; then
      if [[ "$idx" -le "$RETENTION_KEEP_RECENT" ]]; then
        log "KEEP $snap (within most recent $RETENTION_KEEP_RECENT snapshots)"
        keep="$(add_line_once "$keep" "$snap")"
      else
        log "DELETE $snap (older than most recent $RETENTION_KEEP_RECENT snapshots)"
      fi
      continue
    fi

    if ! epoch="$(snapshot_epoch "$snap" 2>/dev/null)"; then
      log "KEEP $snap (could not parse timestamp)"
      keep="$(add_line_once "$keep" "$snap")"
      continue
    fi

    age=$((now_epoch - epoch))
    if [[ "$age" -lt 0 ]]; then
      log "KEEP $snap (timestamp is in the future)"
      keep="$(add_line_once "$keep" "$snap")"
      continue
    fi

    if [[ "$age" -le $((RETENTION_HOURLY * 3600)) ]]; then
      log "KEEP $snap (within hourly window: ${RETENTION_HOURLY}h)"
      keep="$(add_line_once "$keep" "$snap")"
      continue
    fi

    if [[ "$age" -le $((RETENTION_DAILY * 86400)) ]]; then
      bucket="$(snapshot_fmt "$snap" '+%Y-%m-%d')"
      if ! contains_line "$daily_buckets" "$bucket"; then
        daily_buckets="$(add_line_once "$daily_buckets" "$bucket")"
        log "KEEP $snap (daily representative: $bucket)"
        keep="$(add_line_once "$keep" "$snap")"
      else
        log "DELETE $snap (extra daily snapshot: $bucket)"
      fi
      continue
    fi

    if [[ "$age" -le $((RETENTION_WEEKLY * 7 * 86400)) ]]; then
      bucket="$(snapshot_fmt "$snap" '+%Y-W%U')"
      if ! contains_line "$weekly_buckets" "$bucket"; then
        weekly_buckets="$(add_line_once "$weekly_buckets" "$bucket")"
        log "KEEP $snap (weekly representative: $bucket)"
        keep="$(add_line_once "$keep" "$snap")"
      else
        log "DELETE $snap (extra weekly snapshot: $bucket)"
      fi
      continue
    fi

    if [[ "$age" -le $((RETENTION_MONTHLY * 31 * 86400)) ]]; then
      bucket="$(snapshot_fmt "$snap" '+%Y-%m')"
      if ! contains_line "$monthly_buckets" "$bucket"; then
        monthly_buckets="$(add_line_once "$monthly_buckets" "$bucket")"
        log "KEEP $snap (monthly representative: $bucket)"
        keep="$(add_line_once "$keep" "$snap")"
      else
        log "DELETE $snap (extra monthly snapshot: $bucket)"
      fi
      continue
    fi

    log "DELETE $snap (outside retention policy)"
  done

  KEEP_LIST="$keep"
}

run_prune() {
  local dry_run="$1"
  local stamp latest now_epoch snap snapshot_count
  stamp="$(timestamp)"
  setup_prune_log "$stamp"

  load_config
  parse_snapshot_root
  require_managed_target
  safe_root_or_die

  log "backup-agent prune starting: mode=$([[ "$dry_run" == true ]] && printf dry-run || printf run)"
  log "target: $(target_display_root)"

  SNAPSHOTS_DESC=()
  snapshot_count=0
  while IFS= read -r snap; do
    if [[ -n "$snap" ]]; then
      SNAPSHOTS_DESC[$snapshot_count]="$snap"
      snapshot_count=$((snapshot_count + 1))
    fi
  done < <(list_snapshots | sort -r)

  if [[ "$snapshot_count" -eq 0 ]]; then
    log "no snapshots found; nothing to prune."
    return 0
  fi

  latest="$(latest_snapshot_name)"
  now_epoch="$(date '+%s')"
  KEEP_LIST=""
  choose_snapshots_to_keep "$latest" "$now_epoch"

  for snap in "${SNAPSHOTS_DESC[@]}"; do
    if contains_line "$KEEP_LIST" "$snap"; then
      continue
    fi
    safe_snapshot_name "$snap" || die "Refusing to delete malformed snapshot name: $snap"
    if [[ "$dry_run" == true ]]; then
      log "DRY-RUN would delete snapshots/$snap"
    else
      log "deleting snapshots/$snap"
      delete_remote_tree "snapshots/$snap"
    fi
  done

  log "prune complete."
}

list_policy() {
  load_config
  parse_snapshot_root
  cat <<EOF
Retention policy:
  RETENTION_KEEP_RECENT=$RETENTION_KEEP_RECENT
  RETENTION_HOURLY=$RETENTION_HOURLY
  RETENTION_DAILY=$RETENTION_DAILY
  RETENTION_WEEKLY=$RETENTION_WEEKLY
  RETENTION_MONTHLY=$RETENTION_MONTHLY

Current snapshots:
EOF
  list_snapshots
}

case "${1:-dry-run}" in
  dry-run) run_prune true ;;
  run) run_prune false ;;
  list) list_policy ;;
  -h|--help|help) usage ;;
  *) usage; exit 2 ;;
esac
