#!/usr/bin/env bash
set -euo pipefail

# Install the Restic external-disk system backup service/timer.
#
# Expected files beside this installer:
#   restic-system-backup.sh
#   restic-disk-restore.sh
#   restic-system-backup.service
#   restic-system-backup.timer
#   backups-disk.env.template
#   excludes.txt
#
# Usage:
#   ./install-restic-disk-system-backup.sh
#   ./install-restic-disk-system-backup.sh --enable
#   ./install-restic-disk-system-backup.sh --dry-run

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME='restic-system-backup'
RESTIC_DIR='/etc/restic'

SCRIPT_SRC="${SCRIPT_DIR}/${SERVICE_NAME}.sh"
RESTORE_SRC="${SCRIPT_DIR}/restic-disk-restore.sh"
SERVICE_SRC="${SCRIPT_DIR}/${SERVICE_NAME}.service"
TIMER_SRC="${SCRIPT_DIR}/${SERVICE_NAME}.timer"
ENV_TEMPLATE_SRC="${SCRIPT_DIR}/backups-disk.env.template"
EXCLUDES_SRC="${SCRIPT_DIR}/excludes.txt"

SCRIPT_DST="/usr/local/sbin/${SERVICE_NAME}"
RESTORE_DST="/usr/local/sbin/restic-disk-restore"
SERVICE_DST="/etc/systemd/system/${SERVICE_NAME}.service"
TIMER_DST="/etc/systemd/system/${SERVICE_NAME}.timer"
ENV_DST="${RESTIC_DIR}/backups-disk.env"
ENV_EXAMPLE_DST="${RESTIC_DIR}/backups-disk.env.example"
EXCLUDES_DST="${RESTIC_DIR}/excludes.txt"
PASSWORD_DST="${RESTIC_DIR}/backup-password"

ENABLE_TIMER=0
GENERATE_PASSWORD=1
DRY_RUN=0

usage() { sed -n '1,20p' "$0" | sed 's/^# \{0,1\}//'; }
for arg in "$@"; do
  case "$arg" in
    --enable) ENABLE_TIMER=1 ;;
    --no-password-generate) GENERATE_PASSWORD=0 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

need_file() { [[ -f "$1" ]] || { echo "Missing required source file: $1" >&2; exit 1; }; }
sudo_run() {
  printf '+ sudo'; printf ' %q' "$@"; printf '\n'
  [[ "$DRY_RUN" -eq 1 ]] || sudo "$@"
}
sudo_shell() {
  printf '+ sudo sh -c %q\n' "$1"
  [[ "$DRY_RUN" -eq 1 ]] || sudo sh -c "$1"
}

for file in "$SCRIPT_SRC" "$RESTORE_SRC" "$SERVICE_SRC" "$TIMER_SRC" "$ENV_TEMPLATE_SRC" "$EXCLUDES_SRC"; do need_file "$file"; done
command -v systemctl >/dev/null 2>&1 || { echo 'systemctl is required' >&2; exit 1; }
if ! command -v restic >/dev/null 2>&1; then
  echo 'Warning: install Restic before starting the service:' >&2
  echo '  Arch: sudo pacman -S restic' >&2
  echo '  Ubuntu: sudo apt install restic' >&2
fi

echo "Installing ${SERVICE_NAME} from ${SCRIPT_DIR}"
sudo_run install -d -m 700 "$RESTIC_DIR"
sudo_run install -m 700 "$SCRIPT_SRC" "$SCRIPT_DST"
sudo_run install -m 700 "$RESTORE_SRC" "$RESTORE_DST"
sudo_run install -m 644 "$SERVICE_SRC" "$SERVICE_DST"
sudo_run install -m 644 "$TIMER_SRC" "$TIMER_DST"

# The exclude policy is non-secret and updated on every installer run.
sudo_run install -m 644 "$EXCLUDES_SRC" "$EXCLUDES_DST"
# The example is non-secret; the real config is created only once.
sudo_run install -m 600 "$ENV_TEMPLATE_SRC" "$ENV_EXAMPLE_DST"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Would create ${ENV_DST} from template only if missing."
elif sudo test -f "$ENV_DST"; then
  echo "Keeping existing ${ENV_DST}"
else
  sudo install -m 600 "$ENV_TEMPLATE_SRC" "$ENV_DST"
  echo "Created ${ENV_DST}; edit it before running a backup:"
  echo "  sudoedit ${ENV_DST}"
fi

if [[ "$GENERATE_PASSWORD" -eq 1 ]]; then
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "Would generate ${PASSWORD_DST} only if missing."
  elif sudo test -f "$PASSWORD_DST"; then
    echo "Keeping existing ${PASSWORD_DST}"
  else
    sudo_shell "umask 077; openssl rand -base64 48 > '${PASSWORD_DST}'"
    sudo chmod 600 "$PASSWORD_DST"
    echo "Generated ${PASSWORD_DST}. Store it in your password manager."
    echo "View it once with: sudo cat ${PASSWORD_DST}"
  fi
else
  echo "Skipped password generation; create ${PASSWORD_DST} before starting the service."
fi

sudo_run systemctl daemon-reload
if command -v systemd-analyze >/dev/null 2>&1; then
  sudo_run systemd-analyze verify "$SERVICE_DST" "$TIMER_DST"
fi

if [[ "$ENABLE_TIMER" -eq 1 ]]; then
  sudo_run systemctl enable --now "${SERVICE_NAME}.timer"
else
  echo "Timer not enabled. Enable after configuration with:"
  echo "  sudo systemctl enable --now ${SERVICE_NAME}.timer"
fi

echo
echo 'Installed external-disk Restic backup service.'
echo "1. Edit disk identity/repo path: sudoedit ${ENV_DST}"
echo "2. Confirm the password is saved safely: ${PASSWORD_DST}"
echo "3. Run the first backup: sudo systemctl start ${SERVICE_NAME}.service"
echo "4. Watch logs: sudo journalctl -u ${SERVICE_NAME}.service -f"
echo '5. List snapshots: sudo restic-disk-restore list'
echo '6. Restore latest to a safe empty directory: sudo restic-disk-restore restore latest /mnt/restic-restore --verify'
