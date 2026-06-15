#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'PASS: %s\n' "$*"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf 'FAIL: %s\n' "$*"
}

note_warn() {
  WARN_COUNT=$((WARN_COUNT + 1))
  printf 'WARN: %s\n' "$*"
}

check_rsync() {
  if command -v rsync >/dev/null 2>&1; then
    pass "rsync is installed ($(command -v rsync))"
  else
    fail "rsync is not installed."
  fi
}

check_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    pass "config exists: $CONFIG_FILE"
  else
    fail "config missing: $CONFIG_FILE. Copy config.example to config."
    return 1
  fi
}

list_nested_mounts() {
  local root="${1%/}"
  [[ -d "$root" ]] || return 0

  if command -v findmnt >/dev/null 2>&1; then
    findmnt -n -r -o TARGET 2>/dev/null | while IFS= read -r mount_point; do
      [[ -n "$mount_point" && "$mount_point" != "$root" ]] || continue
      case "$mount_point" in
        "$root"/*) printf '%s\n' "$mount_point" ;;
      esac
    done
  else
    mount | sed -n 's/.* on \(.*\) (.*/\1/p' | while IFS= read -r mount_point; do
      [[ -n "$mount_point" && "$mount_point" != "$root" ]] || continue
      case "$mount_point" in
        "$root"/*) printf '%s\n' "$mount_point" ;;
      esac
    done
  fi
}

check_sources() {
  local src expanded label labels="" nested_mounts
  for src in "${SOURCE_PATHS[@]}"; do
    expanded="$(expand_path "$src")"
    if [[ -e "$expanded" ]]; then
      pass "source exists: $src -> $expanded"
      nested_mounts="$(list_nested_mounts "$expanded" | sed 's/^/  /' || true)"
      if [[ -n "$nested_mounts" ]]; then
        if truthy "$ONE_FILE_SYSTEM"; then
          note_warn "source contains nested mount point(s); ONE_FILE_SYSTEM=true will skip crossing them: $src
$nested_mounts"
        else
          fail "source contains nested mount point(s) and ONE_FILE_SYSTEM=false: $src
$nested_mounts"
        fi
      fi
    else
      fail "source missing: $src -> $expanded"
    fi

    label="${expanded%/}"
    label="${label##*/}"
    if [[ -z "$label" || "$label" == "." || "$label" == ".." ]]; then
      fail "source maps to unsafe snapshot folder: $src"
    elif printf '%s\n' "$labels" | grep -qx -- "$label"; then
      fail "duplicate snapshot folder label '$label' from SOURCE_PATHS; use unique basenames."
    else
      labels="${labels}${label}
"
    fi
  done
}

check_excludes() {
  local file resolved
  for file in "${EXCLUDE_FILES[@]:-}"; do
    if [[ "$file" == /* ]]; then
      resolved="$file"
    else
      resolved="$SCRIPT_DIR/$file"
    fi
    if [[ -f "$resolved" ]]; then
      pass "exclude file exists: $file"
    else
      fail "exclude file missing: $file -> $resolved"
    fi
  done
}

check_source_size_limit() {
  if [[ "${MAX_SOURCE_SIZE_GB:-0}" -le 0 ]]; then
    pass "MAX_SOURCE_SIZE_GB check is disabled."
    return
  fi

  local src expanded size_kb total_kb=0 limit_kb
  for src in "${SOURCE_PATHS[@]}"; do
    expanded="$(expand_path "$src")"
    [[ -e "$expanded" ]] || continue
    size_kb="$(source_size_kb "$expanded" || printf '0\n')"
    total_kb=$((total_kb + size_kb))
  done

  limit_kb=$((MAX_SOURCE_SIZE_GB * 1024 * 1024))
  if [[ "$total_kb" -le "$limit_kb" ]]; then
    pass "source size estimate $((total_kb / 1024 / 1024)) GB <= MAX_SOURCE_SIZE_GB ${MAX_SOURCE_SIZE_GB} GB"
  else
    fail "source size estimate $((total_kb / 1024 / 1024)) GB > MAX_SOURCE_SIZE_GB ${MAX_SOURCE_SIZE_GB} GB"
  fi
}

check_target_reachable() {
  case "$TARGET_MODE" in
    ssh)
      if remote_exec "test -d $(shell_quote "${REMOTE_PATH%/*}") || test -d $(shell_quote "$REMOTE_PATH")" >/dev/null 2>&1; then
        pass "SSH target is reachable: $REMOTE_HOST"
      else
        fail "SSH target is not reachable or parent path is missing: $(target_display_root)"
      fi
      ;;
    local)
      if [[ -d "$LOCAL_ROOT" || -d "${LOCAL_ROOT%/*}" ]]; then
        pass "local target path or parent exists: $LOCAL_ROOT"
      else
        fail "local target parent does not exist: ${LOCAL_ROOT%/*}"
      fi
      ;;
    rsync_daemon)
      if rsync "${REMOTE_PATH%/}/" >/dev/null 2>&1; then
        pass "rsync daemon target is reachable: $REMOTE_PATH"
      else
        fail "rsync daemon target is not reachable: $REMOTE_PATH"
      fi
      note_warn "rsync:// targets are reachable by rsync, but cannot provide the required remote rename/latest/prune controls without shell access."
      ;;
  esac
}

check_target_writable_and_hardlinks() {
  local test_dir
  case "$TARGET_MODE" in
    ssh)
      test_dir="$REMOTE_PATH/.validate-backup-agent-$$"
      if remote_exec "mkdir -p $(shell_quote "$test_dir") && printf test > $(shell_quote "$test_dir/a") && ln $(shell_quote "$test_dir/a") $(shell_quote "$test_dir/b") && rm -rf -- $(shell_quote "$test_dir")" >/dev/null 2>&1; then
        pass "target is writable and supports hard links."
      else
        remote_exec "rm -rf -- $(shell_quote "$test_dir")" >/dev/null 2>&1 || true
        fail "target is not writable or hard links are not supported: $(target_display_root)"
      fi
      ;;
    local)
      test_dir="$LOCAL_ROOT/.validate-backup-agent-$$"
      if mkdir -p "$test_dir" && printf test > "$test_dir/a" && ln "$test_dir/a" "$test_dir/b"; then
        rm -rf -- "$test_dir"
        pass "target is writable and supports hard links."
      else
        rm -rf -- "$test_dir" || true
        fail "target is not writable or hard links are not supported: $LOCAL_ROOT"
      fi
      ;;
    rsync_daemon)
      fail "hard-link snapshot mode cannot be safely validated for rsync:// targets. Use SSH-style BACKUP_TARGET for this tool."
      ;;
  esac
}

check_free_space() {
  if [[ "${MIN_FREE_SPACE_GB:-0}" -le 0 || "$TARGET_MODE" == "rsync_daemon" ]]; then
    pass "MIN_FREE_SPACE_GB check is disabled."
    return
  fi

  local free_gb
  free_gb="$(available_gb 2>/dev/null || printf '0\n')"
  if [[ "$free_gb" -ge "$MIN_FREE_SPACE_GB" ]]; then
    pass "target free space ${free_gb} GB >= MIN_FREE_SPACE_GB ${MIN_FREE_SPACE_GB} GB"
  else
    fail "target free space ${free_gb} GB < MIN_FREE_SPACE_GB ${MIN_FREE_SPACE_GB} GB"
  fi
}

main() {
  printf 'backup-agent validation\n'
  printf 'Config: %s\n\n' "$CONFIG_FILE"

  check_rsync
  if ! check_config; then
    printf '\nSummary: %d pass, %d warn, %d fail\n' "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT"
    exit 1
  fi

  load_config
  parse_snapshot_root
  printf 'Machine: %s\n' "$MACHINE_NAME"
  printf 'Target:  %s\n\n' "$(target_display_root)"

  check_sources
  check_excludes
  check_source_size_limit
  check_target_reachable
  check_target_writable_and_hardlinks
  check_free_space

  printf '\nSummary: %d pass, %d warn, %d fail\n' "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT"
  if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
  fi
}

main "$@"
