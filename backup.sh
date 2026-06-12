#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
Usage:
  ./backup.sh run
  ./backup.sh dry-run
  ./backup.sh list
  ./backup.sh latest
  ./backup.sh restore-help

Environment:
  BACKUP_AGENT_CONFIG=/path/to/config  Use an alternate config file.
EOF
}

resolve_exclude_file() {
  local file="$1"
  if [[ "$file" == /* ]]; then
    printf '%s\n' "$file"
  else
    printf '%s/%s\n' "$SCRIPT_DIR" "$file"
  fi
}

source_label() {
  local src="$1"
  src="${src%/}"
  local label="${src##*/}"
  [[ -n "$label" && "$label" != "." && "$label" != ".." ]] || die "Cannot derive a safe snapshot folder name from source: $src"
  printf '%s\n' "$label"
}

rsync_source_arg() {
  local src="$1"
  if [[ -d "$src" ]]; then
    printf '%s/\n' "${src%/}"
  else
    printf '%s\n' "$src"
  fi
}

build_rsync_args() {
  local dry_run="$1"
  RSYNC_ARGS=(-a --delete --human-readable --stats)

  if truthy "$ONE_FILE_SYSTEM"; then
    RSYNC_ARGS+=(--one-file-system)
  fi

  if truthy "$dry_run"; then
    RSYNC_ARGS+=(--dry-run --itemize-changes)
  elif truthy "$VERBOSE"; then
    RSYNC_ARGS+=(--itemize-changes)
  fi

  local exclude_file resolved
  for exclude_file in "${EXCLUDE_FILES[@]:-}"; do
    resolved="$(resolve_exclude_file "$exclude_file")"
    RSYNC_ARGS+=("--exclude-from=$resolved")
  done

  if [[ "$TARGET_MODE" == "ssh" ]]; then
    RSYNC_ARGS+=(-e "$(rsync_ssh_args)")
  fi
}

ensure_sources_exist() {
  local src expanded
  for src in "${SOURCE_PATHS[@]}"; do
    expanded="$(expand_path "$src")"
    [[ -e "$expanded" ]] || die "Source path does not exist: $src -> $expanded"
  done
}

ensure_unique_labels() {
  local labels="" src expanded label
  for src in "${SOURCE_PATHS[@]}"; do
    expanded="$(expand_path "$src")"
    label="$(source_label "$expanded")"
    if printf '%s\n' "$labels" | grep -qx -- "$label"; then
      die "Two SOURCE_PATHS map to the same snapshot folder '$label'. Use unique source basenames."
    fi
    labels="${labels}${label}
"
  done
}

prepare_tmp_root() {
  local tmp="$1"
  safe_rel_name "$tmp" || die "Refusing malformed temp snapshot name: $tmp"
  case "$TARGET_MODE" in
    ssh)
      remote_exec "mkdir -p $(shell_quote "$REMOTE_PATH/$tmp")"
      ;;
    local)
      mkdir -p "$LOCAL_ROOT/$tmp"
      ;;
  esac
}

acquire_run_lock() {
  LOCK_DIR="$SCRIPT_DIR/.backup.lock"
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" > "$LOCK_DIR/pid"
    LOCK_TAKEN=true
    return 0
  fi
  die "Another backup appears to be running. Lock exists: $LOCK_DIR"
}

release_run_lock() {
  if [[ "${LOCK_TAKEN:-false}" == true ]]; then
    rm -rf -- "$LOCK_DIR"
    LOCK_TAKEN=false
  fi
}

cleanup_stale_incomplete() {
  local current_tmp="$1"
  local stale

  if ! truthy "$CLEAN_STALE_INCOMPLETE"; then
    log "stale incomplete cleanup disabled."
    return 0
  fi

  while IFS= read -r stale; do
    [[ -n "$stale" ]] || continue
    [[ "$stale" == "$current_tmp" ]] && continue
    case "$stale" in
      .incomplete-*)
        log "removing stale incomplete snapshot before backup: $stale"
        delete_remote_tree "$stale"
        ;;
      *)
        warn "Ignoring unexpected incomplete snapshot name: $stale"
        ;;
    esac
  done < <(list_incomplete_snapshots)
}

choose_available_snapshot_stamp() {
  local candidate="$1"
  local attempts=0

  while snapshot_exists "$candidate"; do
    attempts=$((attempts + 1))
    if [[ "$attempts" -gt 10 ]]; then
      die "Could not find an unused snapshot timestamp after $attempts attempts."
    fi
    warn "snapshot already exists: $candidate; waiting for a fresh timestamp."
    sleep 1
    candidate="$(timestamp)"
  done

  printf '%s\n' "$candidate"
}

run_backup() {
  local dry_run="$1"
  local stamp tmp previous cleanup_needed free_gb initial_stamp
  acquire_run_lock
  trap 'release_run_lock' EXIT INT TERM
  load_config
  stamp="$(timestamp)"
  initial_stamp="$stamp"
  setup_log "$stamp"
  tmp=".incomplete-$stamp-$$"
  cleanup_needed=false

  log "backup-agent starting: mode=$([[ "$dry_run" == true ]] && printf dry-run || printf run)"
  if [[ -n "${BACKUP_TIMEZONE:-}" ]]; then
    log "backup timezone: $BACKUP_TIMEZONE"
  fi
  parse_snapshot_root
  require_managed_target
  safe_root_or_die
  ensure_sources_exist
  ensure_unique_labels
  build_rsync_args "$dry_run"

  target_mkdirs
  stamp="$(choose_available_snapshot_stamp "$stamp")"
  if [[ "$stamp" != "$initial_stamp" ]]; then
    tmp=".incomplete-$stamp-$$"
    log "using alternate snapshot timestamp: $stamp"
  fi

  if ! truthy "$dry_run"; then
    cleanup_stale_incomplete "$tmp"
  fi

  if [[ "${MIN_FREE_SPACE_GB:-0}" -gt 0 ]]; then
    free_gb="$(available_gb)"
    log "free space at target: ${free_gb} GB"
    if [[ "$free_gb" -lt "$MIN_FREE_SPACE_GB" ]]; then
      die "Target has ${free_gb} GB free, below MIN_FREE_SPACE_GB=${MIN_FREE_SPACE_GB}."
    fi
  fi

  previous="$(latest_snapshot_name)"
  if [[ -n "$previous" ]]; then
    if safe_snapshot_name "$previous" && snapshot_exists "$previous"; then
      log "previous snapshot: $previous"
    else
      warn "latest points to missing or malformed snapshot '$previous'; running without --link-dest."
      previous=""
    fi
  else
    log "previous snapshot: none"
  fi

  prepare_tmp_root "$tmp"
  cleanup_needed=true

  cleanup() {
    local status=$?
    if [[ "${cleanup_needed:-false}" == true ]]; then
      log "cleaning incomplete snapshot: $tmp"
      delete_remote_tree "$tmp" || true
    fi
    release_run_lock
    exit "$status"
  }
  trap cleanup EXIT INT TERM

  local src expanded label dest src_arg link_dest_arg
  for src in "${SOURCE_PATHS[@]}"; do
    expanded="$(expand_path "$src")"
    label="$(source_label "$expanded")"
    src_arg="$(rsync_source_arg "$expanded")"
    link_dest_arg=()

    if [[ -d "$expanded" ]]; then
      dest="$(target_rsync_path "$tmp/$label/")"
      if [[ -n "$previous" ]]; then
        # Relative to the per-source destination directory:
        #   .incomplete-.../<label>/ -> snapshots/<previous>/<label>/
        link_dest_arg=("--link-dest=../../snapshots/$previous/$label")
      fi
      log "rsync source '$expanded' -> '$label/'"
    else
      dest="$(target_rsync_path "$tmp/")"
      if [[ -n "$previous" ]]; then
        # Relative to the snapshot root:
        #   .incomplete-.../ -> snapshots/<previous>/
        link_dest_arg=("--link-dest=../snapshots/$previous")
      fi
      log "rsync source '$expanded' -> '$label'"
    fi

    if [[ -n "$previous" ]]; then
      rsync "${RSYNC_ARGS[@]}" "${link_dest_arg[@]}" "$src_arg" "$dest" 2>&1 | tee -a "$LOG_FILE"
    else
      rsync "${RSYNC_ARGS[@]}" "$src_arg" "$dest" 2>&1 | tee -a "$LOG_FILE"
    fi
  done

  if truthy "$dry_run"; then
    log "cleaning dry-run staging directory if rsync created it: $tmp"
    delete_remote_tree "$tmp" || true
    log "dry run complete; no snapshot was created."
    cleanup_needed=false
    trap - EXIT INT TERM
    release_run_lock
    return 0
  fi

  rename_incomplete_snapshot "$tmp" "$stamp"
  cleanup_needed=false
  update_latest "$stamp"
  log "snapshot complete: snapshots/$stamp"
  log "latest updated: latest -> snapshots/$stamp"

  if truthy "$PRUNE_AFTER_BACKUP"; then
    log "PRUNE_AFTER_BACKUP=true; running prune.sh run"
    "$SCRIPT_DIR/prune.sh" run 2>&1 | tee -a "$LOG_FILE"
  else
    log "pruning skipped; run ./prune.sh dry-run first, then ./prune.sh run when ready."
  fi

  trap - EXIT INT TERM
  release_run_lock
}

list_action() {
  load_config
  parse_snapshot_root
  list_snapshots
}

latest_action() {
  load_config
  parse_snapshot_root
  local latest
  latest="$(latest_snapshot_name)"
  if [[ -z "$latest" ]]; then
    die "No latest snapshot found."
  fi
  printf '%s\n' "$(target_display_root)/snapshots/$latest"
}

restore_help() {
  load_config
  parse_snapshot_root
  cat <<EOF
Manual restore workflow:

1. List snapshots:
   ./backup.sh list

2. Browse a snapshot on the NAS:
   $(target_display_root)/snapshots/<timestamp>/

3. Copy files back with rsync or cp.
   Example:
   rsync -a "$(target_display_root)/snapshots/<timestamp>/Documents/file.txt" "\$HOME/Documents/file.txt"

For SSH targets, you can also pull directly:
   rsync -a "$(target_display_root)/snapshots/<timestamp>/Documents/" "\$HOME/Documents/"

This tool does not overwrite source files during backup. Restores are manual so you can inspect exactly what will be copied back.
EOF
}

action="${1:-}"
if [[ -z "$action" ]]; then
  load_config
  if truthy "${DRY_RUN_BY_DEFAULT:-true}"; then
    action="dry-run"
  else
    action="run"
  fi
fi

case "$action" in
  run) run_backup false ;;
  dry-run) run_backup true ;;
  list) list_action ;;
  latest) latest_action ;;
  restore-help) restore_help ;;
  -h|--help|help) usage ;;
  *) usage; exit 2 ;;
esac
