#!/usr/bin/env bash
set -euo pipefail

# Root system backup to Cloudflare R2 using Restic's S3 backend.
# Configuration and credentials: /etc/restic/r2.env
# Shared exclusion policy:      /etc/restic/excludes.txt

ENV_FILE='/etc/restic/r2.env'
DEFAULT_PASSWORD_FILE='/etc/restic/backup-password'
DEFAULT_EXCLUDE_FILE='/etc/restic/excludes.txt'
DEFAULT_CACHE_DIR='/var/cache/restic/r2'

log() {
  printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*"
}

restic_cmd() {
  restic --cache-dir "$RESTIC_CACHE_DIR" "$@"
}

[[ $EUID -eq 0 ]] || { echo 'This script must run as root' >&2; exit 1; }
command -v restic >/dev/null 2>&1 || { echo 'restic is not installed' >&2; exit 1; }
[[ -r "$ENV_FILE" ]] || { echo "Missing Restic/R2 env file: $ENV_FILE" >&2; exit 1; }

# The env file is root-owned, mode 600, and intentionally contains R2 credentials.
# shellcheck disable=SC1090
source "$ENV_FILE"

BACKUP_USER="${BACKUP_USER:-reyidaas}"
USER_HOME="/home/${BACKUP_USER}"
RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-$DEFAULT_PASSWORD_FILE}"
EXCLUDE_FILE="${EXCLUDE_FILE:-$DEFAULT_EXCLUDE_FILE}"
RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-$DEFAULT_CACHE_DIR}"
RETENTION_KEEP_LAST="${RETENTION_KEEP_LAST:-3}"
RETENTION_KEEP_DAILY="${RETENTION_KEEP_DAILY:-7}"
RETENTION_KEEP_WEEKLY="${RETENTION_KEEP_WEEKLY:-4}"
RETENTION_KEEP_MONTHLY="${RETENTION_KEEP_MONTHLY:-12}"
RETENTION_KEEP_YEARLY="${RETENTION_KEEP_YEARLY:-3}"

: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY is not set in $ENV_FILE}"
: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID is not set in $ENV_FILE}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY is not set in $ENV_FILE}"
[[ -r "$RESTIC_PASSWORD_FILE" ]] || { echo "Missing Restic password file: $RESTIC_PASSWORD_FILE" >&2; exit 1; }
[[ -r "$EXCLUDE_FILE" ]] || { echo "Missing Restic exclude file: $EXCLUDE_FILE" >&2; exit 1; }
mkdir -p "$RESTIC_CACHE_DIR"
chmod 700 "$RESTIC_CACHE_DIR"

# Cloudflare R2 uses the S3 API and generally expects region 'auto'.
export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-auto}"
export AWS_REGION="${AWS_REGION:-auto}"

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

log "Starting Restic backup to R2 repository ${RESTIC_REPOSITORY}"
restic_cmd backup "${sources[@]}" \
  --one-file-system \
  --exclude-caches \
  --exclude-file="$EXCLUDE_FILE" \
  --tag systemd --tag r2 --tag "$(hostname)"

log "Applying retention policy: last=${RETENTION_KEEP_LAST}, daily=${RETENTION_KEEP_DAILY}, weekly=${RETENTION_KEEP_WEEKLY}, monthly=${RETENTION_KEEP_MONTHLY}, yearly=${RETENTION_KEEP_YEARLY}"
restic_cmd forget \
  --host "$(hostname)" \
  --tag systemd --tag r2 \
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
