# backup-agent

A small, portable rsync snapshot backup directory for Linux and macOS machines.

It creates Time Machine-style timestamped snapshots on a NAS using `rsync -a --delete --link-dest`. Unchanged files are hard-linked from the previous snapshot, so each snapshot looks complete while only changed file data consumes new space.

## Public Sharing Safety

This repository is intended to be safe to share publicly.

- `config.example` contains placeholders only.
- Your real `config` file is ignored by Git.
- Generated logs under `logs/` are ignored by Git.
- Do not commit real NAS hostnames, usernames, internal paths, source path lists from work machines, SSH keys, tokens, or backup logs.
- Keep per-machine settings in the local `config` file copied from `config.example`.

## What It Does

- Backs up only the paths listed in `SOURCE_PATHS`.
- Writes each machine into its own namespace on the NAS.
- Builds each new snapshot in `.incomplete-*` first.
- Removes stale `.incomplete-*` directories from older failed or interrupted real backup runs before starting a new real snapshot.
- Moves the completed snapshot into `snapshots/YYYY-MM-DD_HH-MM-SS/` only after rsync succeeds.
- Updates `latest` only after success.
- Cleans incomplete snapshots after failures or interrupts.
- Provides dry-run backup and dry-run pruning.
- Installs a scheduled job with systemd user timers, cron, or macOS launchd.

## What It Does Not Do

- It does not encrypt backups unless your NAS or storage layer provides encryption.
- It does not provide a restore UI.
- It does not create a daemon or web service.
- It does not use Borg, Restic, Time Machine, Docker, or backup frameworks.
- It is not ideal for live databases or VM disk images unless those are quiesced or snapshotted first.

## Target Support

Use an SSH-style rsync destination for full functionality:

```bash
BACKUP_TARGET="backup-user@nas.local:/volume/backups"
SNAPSHOT_ROOT="${BACKUP_TARGET}/${MACHINE_NAME}"

# Optional when the NAS uses a non-default SSH port or key.
SSH_PORT=""
SSH_KEY=""
```

`rsync://...` targets can be checked for reachability, but they do not provide the remote shell operations needed for safe rename, `latest` updates, hard-link validation, and pruning. `validate.sh` will fail hard-link snapshot mode for `rsync://` targets.

## Snapshot Layout

```text
backup-user@nas.local:/volume/backups/my-machine/
  latest -> snapshots/2026-05-15_14-00-00
  snapshots/
    2026-05-15_13-00-00/
      Documents/
      Projects/
      .ssh/
    2026-05-15_14-00-00/
      Documents/
      Projects/
      .ssh/
```

Each `SOURCE_PATHS` entry is copied under a folder named after its basename. For example, `$HOME/Documents` becomes `Documents/`.

## Hard-Link Snapshots

For each source path, the backup uses:

```bash
rsync -a --delete --link-dest=../../snapshots/<previous>/<source-name> <source>/ <new-incomplete>/<source-name>/
```

If a file has not changed since the previous snapshot, rsync creates a hard link to the existing destination file instead of copying file data again.

A hard link is another directory entry pointing at the same file data. Deleting an old snapshot only removes that snapshot's directory entries. File data is removed only when no remaining snapshot links to it. This is why pruning old hard-linked snapshots is safe when done by deleting whole snapshot directories.

Hard links generally require snapshots to live on the same filesystem on the destination. If the NAS target does not support hard links correctly, validation should fail.

## Install On Ubuntu

```bash
cd ~
git clone <your-repo-url> backup-agent
cd backup-agent
cp config.example config
$EDITOR config
./validate.sh
./backup.sh dry-run
./backup.sh run
./install.sh
```

`install.sh` prefers a systemd user timer when available:

```bash
systemctl --user list-timers backup-agent.timer
```

If systemd user timers are unavailable, use cron:

```bash
./install.sh cron
```

Cron jobs do not run while the machine is powered off. systemd timers use `Persistent=true`, which can catch up missed runs after the user session is available.

## Install On macOS

```bash
cd ~
git clone <your-repo-url> backup-agent
cd backup-agent
cp config.example config
$EDITOR config
./validate.sh
./backup.sh dry-run
./backup.sh run
./install.sh
```

macOS installs a LaunchAgent in `~/Library/LaunchAgents`. It runs while the machine is awake. Do not assume a MacBook wakes from closed-lid sleep to run backups.

macOS includes rsync. Homebrew rsync is optional.

## Configuration

Edit `config`:

```bash
MACHINE_NAME=""
BACKUP_TARGET="backup-user@nas.local:/volume/backups"
SNAPSHOT_ROOT="${BACKUP_TARGET}/${MACHINE_NAME:-$(hostname -s 2>/dev/null || hostname)}"

SSH_PORT=""
SSH_KEY=""

SOURCE_PATHS=(
  "$HOME/Documents"
  "$HOME/Projects"
  "$HOME/.ssh"
)

EXCLUDE_FILES=(
  "excludes.common"
  "excludes.dev"
  "excludes.linux"
  "excludes.mac"
)
```

For personal Linux machines, backing up selected home directories is reasonable. For work machines, prefer explicitly included personal directories only. Do not try to infer confidential files by extension alone. Avoid broad folders like `~/Desktop` or `~/Documents` on a work machine unless that is explicitly intended.

## Dry Run

```bash
./validate.sh
./backup.sh dry-run
```

Dry run shows what rsync would transfer without creating a completed snapshot or updating `latest`.

## Real Backup

```bash
./backup.sh run
```

Logs are written to:

```text
logs/backup-YYYY-MM-DD_HH-MM-SS.log
logs/latest.log
```

## List Snapshots

```bash
./backup.sh list
./backup.sh latest
```

## Restore Files

There is no restore UI. Browse snapshots manually on the NAS and copy files back with `rsync` or `cp`.

Example:

```bash
rsync -a backup-user@nas.local:/volume/backups/my-machine/snapshots/2026-05-15_14-00-00/Documents/file.txt "$HOME/Documents/file.txt"
```

Restore a directory:

```bash
rsync -a backup-user@nas.local:/volume/backups/my-machine/snapshots/2026-05-15_14-00-00/Documents/ "$HOME/Documents/"
```

For help:

```bash
./backup.sh restore-help
```

## Pruning

Pruning is explicit. Backups do not delete old snapshots unless `PRUNE_AFTER_BACKUP=true` is set in `config`.

Always inspect first:

```bash
./prune.sh dry-run
./prune.sh run
```

Default retention:

- Keep all snapshots from the last `RETENTION_HOURLY` hours.
- Keep one daily snapshot for the last `RETENTION_DAILY` days.
- Keep one weekly snapshot for the last `RETENTION_WEEKLY` weeks.
- Keep one monthly snapshot for the last `RETENTION_MONTHLY` months.

Recent-snapshot floor:

```bash
RETENTION_KEEP_RECENT=100
```

When `RETENTION_KEEP_RECENT` is positive, pruning always keeps at least the most recent N snapshots in addition to the hourly/daily/weekly/monthly policy.

## Scheduling

`BACKUP_FREQUENCY` supports:

- `hourly`
- `daily`
- `weekly`

For cron installs, you may use a five-field cron expression. For systemd installs, you may use an `OnCalendar` expression.

Ubuntu:

- Prefer systemd user timers.
- Cron is supported as a fallback.
- Cron does not catch up missed jobs while the machine is off.

macOS:

- Uses launchd LaunchAgents.
- Jobs run while the machine is awake.
- Closed sleeping laptops generally do not wake to run backups.

## Example: Personal Ubuntu Server

```bash
MACHINE_NAME="ubuntu-server-01"
BACKUP_TARGET="backup-user@nas.local:/volume/backups"
SNAPSHOT_ROOT="${BACKUP_TARGET}/${MACHINE_NAME}"
SSH_PORT=""
SSH_KEY=""

SOURCE_PATHS=(
  "$HOME/Documents"
  "$HOME/Projects"
  "$HOME/.ssh"
  "$HOME/.config"
)

EXCLUDE_FILES=(
  "excludes.common"
  "excludes.dev"
  "excludes.linux"
)

BACKUP_FREQUENCY="hourly"
RETENTION_HOURLY=24
RETENTION_DAILY=14
RETENTION_WEEKLY=8
RETENTION_MONTHLY=12
MIN_FREE_SPACE_GB=50
DRY_RUN_BY_DEFAULT=true
PRUNE_AFTER_BACKUP=false
```

## Example: Work macOS Selective Backup

```bash
MACHINE_NAME="work-macbook"
BACKUP_TARGET="backup-user@nas.local:/volume/backups"
SNAPSHOT_ROOT="${BACKUP_TARGET}/${MACHINE_NAME}"
SSH_PORT=""
SSH_KEY=""

# Include only known-safe personal folders. Avoid broad Desktop/Documents
# unless you explicitly intend to back them up from this work machine.
SOURCE_PATHS=(
  "$HOME/Personal"
  "$HOME/.ssh"
)

EXCLUDE_FILES=(
  "excludes.common"
  "excludes.dev"
  "excludes.mac"
)

BACKUP_FREQUENCY="hourly"
RETENTION_KEEP_RECENT=72
MIN_FREE_SPACE_GB=20
DRY_RUN_BY_DEFAULT=true
PRUNE_AFTER_BACKUP=false
```

## Safe Testing

1. Use a temporary target namespace first:

   ```bash
   MACHINE_NAME="test-$(hostname -s)"
   ```

2. Keep `SOURCE_PATHS` small, such as a test folder with a few files.

3. Run:

   ```bash
   ./validate.sh
   ./backup.sh dry-run
   ./backup.sh run
   ./backup.sh list
   ./prune.sh dry-run
   ```

4. Inspect the NAS snapshot manually before enabling scheduling.

## Limitations

- No built-in encryption.
- No application-consistent database backups.
- No special handling for live VM disk images.
- Network rsync jobs can be interrupted; the active incomplete snapshot is cleaned up by the script, and stale incomplete snapshots are cleaned before the next real run.
- Hard links require destination support and usually the same destination filesystem.
- `rsync://` targets are not enough for this implementation's safe snapshot lifecycle.
- Paths with unusual shell characters on the remote destination are best avoided.
