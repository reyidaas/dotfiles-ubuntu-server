#!/usr/bin/env bash
set -euo pipefail

# Root system backup to a labelled external disk using Restic.
# Configuration:                 /etc/restic/backups-disk.env
# Shared exclusion policy:       /etc/restic/excludes.txt

ENV_FILE='/etc/restic/backups-disk.env'
DEFAULT_PASSWORD_FILE='/etc/restic/backup-password'
DEFAULT_EXCLUDE_FILE='/etc/restic/excludes.txt'
DEFAULT_CACHE_DIR='/var/cache/restic/disk'

log() {
  printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*"
}

restic_cmd() {
  restic --cache-dir "$RESTIC_CACHE_DIR" "$@"
}

[[ $EUID -eq 0 ]] || { echo 'This script must run as root' >&2; exit 1; }
command -v restic >/dev/null 2>&1 || { echo 'restic is not installed' >&2; exit 1; }
[[ -r "$ENV_FILE" ]] || { echo "Missing disk backup config: $ENV_FILE" >&2; exit 1; }

# The env file is root-owned, mode 600. It defines disk identity and repository path.
# shellcheck disable=SC1090
source "$ENV_FILE"

BACKUP_USER="${BACKUP_USER:-reyidaas}"
USER_HOME="/home/${BACKUP_USER}"
DISK_LABEL="${DISK_LABEL:?DISK_LABEL is not set in $ENV_FILE}"
MOUNT_POINT="${MOUNT_POINT:?MOUNT_POINT is not set in $ENV_FILE}"
REPOSITORY_DIR="${REPOSITORY_DIR:?REPOSITORY_DIR is not set in $ENV_FILE}"
RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-$DEFAULT_PASSWORD_FILE}"
EXCLUDE_FILE="${EXCLUDE_FILE:-$DEFAULT_EXCLUDE_FILE}"
RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-$DEFAULT_CACHE_DIR}"
RETENTION_KEEP_LAST="${RETENTION_KEEP_LAST:-3}"
RETENTION_KEEP_DAILY="${RETENTION_KEEP_DAILY:-7}"
RETENTION_KEEP_WEEKLY="${RETENTION_KEEP_WEEKLY:-4}"
RETENTION_KEEP_MONTHLY="${RETENTION_KEEP_MONTHLY:-12}"
RETENTION_KEEP_YEARLY="${RETENTION_KEEP_YEARLY:-3}"

[[ -r "$RESTIC_PASSWORD_FILE" ]] || { echo "Missing Restic password file: $RESTIC_PASSWORD_FILE" >&2; exit 1; }
[[ -r "$EXCLUDE_FILE" ]] || { echo "Missing Restic exclude file: $EXCLUDE_FILE" >&2; exit 1; }
mkdir -p "$RESTIC_CACHE_DIR"
chmod 700 "$RESTIC_CACHE_DIR"

DEVICE_LINK="/dev/disk/by-label/${DISK_LABEL}"
if [[ ! -e "$DEVICE_LINK" ]]; then
  echo "Backup disk with label '${DISK_LABEL}' is not attached; skipping." >&2
  exit 75
fi
DEVICE="$(readlink -f "$DEVICE_LINK")"

mkdir -p "$MOUNT_POINT"
if ! findmnt -rn --target "$MOUNT_POINT" >/dev/null 2>&1; then
  log "Mounting ${DEVICE} at ${MOUNT_POINT}"
  mount "$DEVICE" "$MOUNT_POINT"
fi

MOUNTED_SOURCE="$(findmnt -rn -o SOURCE --target "$MOUNT_POINT" || true)"
if [[ "$MOUNTED_SOURCE" != "$DEVICE" ]]; then
  echo "${MOUNT_POINT} is not mounted from expected backup device ${DEVICE} (found: ${MOUNTED_SOURCE:-none})" >&2
  exit 1
fi

# Do not allow traversal outside the mounted backup disk.
case "$REPOSITORY_DIR" in
  /*|*'..'*) echo "REPOSITORY_DIR must be a safe relative path: $REPOSITORY_DIR" >&2; exit 1 ;;
esac

export RESTIC_REPOSITORY="${MOUNT_POINT}/${REPOSITORY_DIR}"
export RESTIC_PASSWORD_FILE
mkdir -p "$RESTIC_REPOSITORY"

# Capture package manifests for a reproducible package baseline on Arch or Debian/Ubuntu.
mkdir -p "${USER_HOME}/.local/state/system-backup"
if command -v pacman >/dev/null 2>&1; then
  pacman -Qqen > "${USER_HOME}/.local/state/system-backup/pacman-native.txt" || true
  pacman -Qqem > "${USER_HOME}/.local/state/system-backup/pacman-foreign.txt" || true
fi
if command -v dpkg-query >/dev/null 2>&1; then
  dpkg-query -W -f='${binary:Package}\t${Version}\n' > "${USER_HOME}/.local/state/system-backup/dpkg-packages.txt" || true
fi
chown -R "${BACKUP_USER}:${BACKUP_USER}" "${USER_HOME}/.local/state/system-backup" || true

if ! restic_cmd cat config >/dev/null 2>&1; then
  log "Initializing Restic repository at ${RESTIC_REPOSITORY}"
  restic_cmd init
fi

sources=()
for path in "$USER_HOME" /etc /root /usr/local /srv /boot /boot/efi /opt/firecrawl /var/lib/tailscale /var/lib/nordvpn; do
  [[ -e "$path" ]] && sources+=("$path")
done
[[ ${#sources[@]} -gt 0 ]] || { echo 'No backup sources exist; refusing to run.' >&2; exit 1; }

log "Starting Restic backup to local repository ${RESTIC_REPOSITORY}"
restic_cmd backup "${sources[@]}" \
  --one-file-system \
  --exclude-caches \
  --exclude-file="$EXCLUDE_FILE" \
  --tag systemd --tag disk --tag "$(hostname)"

log "Applying retention policy: last=${RETENTION_KEEP_LAST}, daily=${RETENTION_KEEP_DAILY}, weekly=${RETENTION_KEEP_WEEKLY}, monthly=${RETENTION_KEEP_MONTHLY}, yearly=${RETENTION_KEEP_YEARLY}"
restic_cmd forget \
  --host "$(hostname)" \
  --tag systemd --tag disk \
  --group-by host,tags \
  --keep-last "$RETENTION_KEEP_LAST" \
  --keep-daily "$RETENTION_KEEP_DAILY" \
  --keep-weekly "$RETENTION_KEEP_WEEKLY" \
  --keep-monthly "$RETENTION_KEEP_MONTHLY" \
  --keep-yearly "$RETENTION_KEEP_YEARLY" \
  --prune

log 'Checking a 1% random data subset for repository integrity'
restic_cmd check --read-data-subset=1/100
log 'Backup done'
