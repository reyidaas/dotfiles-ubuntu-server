#!/usr/bin/env bash
set -euo pipefail

# Install the Restic Cloudflare R2 system backup service/timer.
#
# Expected files in the same directory as this installer:
#   restic-r2-system-backup.sh
#   restic-r2-restore.sh
#   restic-r2-system-backup.service
#   restic-r2-system-backup.timer
#   r2.env.template
#   excludes.txt
#
# Installs to:
#   /usr/local/sbin/restic-r2-system-backup
#   /etc/systemd/system/restic-r2-system-backup.service
#   /etc/systemd/system/restic-r2-system-backup.timer
#   /etc/restic/r2.env                 # created from template only if missing
#   /etc/restic/backup-password        # generated only if missing, unless disabled
#
# Usage:
#   ./install-restic-r2-system-backup.sh
#   ./install-restic-r2-system-backup.sh --enable
#   ./install-restic-r2-system-backup.sh --enable --no-password-generate
#   ./install-restic-r2-system-backup.sh --dry-run

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

SERVICE_NAME="restic-r2-system-backup"
SCRIPT_SRC="${SCRIPT_DIR}/${SERVICE_NAME}.sh"
RESTORE_SRC="${SCRIPT_DIR}/restic-r2-restore.sh"
SERVICE_SRC="${SCRIPT_DIR}/${SERVICE_NAME}.service"
TIMER_SRC="${SCRIPT_DIR}/${SERVICE_NAME}.timer"
ENV_TEMPLATE_SRC="${SCRIPT_DIR}/r2.env.template"
EXCLUDES_SRC="${SCRIPT_DIR}/excludes.txt"

SCRIPT_DST="/usr/local/sbin/${SERVICE_NAME}"
RESTORE_DST="/usr/local/sbin/restic-r2-restore"
SERVICE_DST="/etc/systemd/system/${SERVICE_NAME}.service"
TIMER_DST="/etc/systemd/system/${SERVICE_NAME}.timer"
RESTIC_DIR="/etc/restic"
ENV_DST="${RESTIC_DIR}/r2.env"
ENV_EXAMPLE_DST="${RESTIC_DIR}/r2.env.example"
EXCLUDES_DST="${RESTIC_DIR}/excludes.txt"
PASSWORD_DST="${RESTIC_DIR}/backup-password"

ENABLE_TIMER=0
GENERATE_PASSWORD=1
DRY_RUN=0

usage() {
  sed -n '1,34p' "$0" | sed 's/^# \{0,1\}//'
}

for arg in "$@"; do
  case "$arg" in
    --enable)
      ENABLE_TIMER=1
      ;;
    --no-password-generate)
      GENERATE_PASSWORD=0
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      usage >&2
      exit 2
      ;;
  esac
done

need_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "Missing required source file: $path" >&2
    exit 1
  fi
}

run() {
  printf '+ %q' "$1"
  shift || true
  printf ' %q' "$@"
  printf '\n'
  if [[ "$DRY_RUN" -eq 0 ]]; then
    "$@"
  fi
}

sudo_run() {
  printf '+ sudo'
  printf ' %q' "$@"
  printf '\n'
  if [[ "$DRY_RUN" -eq 0 ]]; then
    sudo "$@"
  fi
}

sudo_shell() {
  local script="$1"
  printf '+ sudo sh -c %q\n' "$script"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    sudo sh -c "$script"
  fi
}

need_file "$SCRIPT_SRC"
need_file "$RESTORE_SRC"
need_file "$SERVICE_SRC"
need_file "$TIMER_SRC"
need_file "$ENV_TEMPLATE_SRC"
need_file "$EXCLUDES_SRC"

if ! command -v systemctl >/dev/null 2>&1; then
  echo "systemctl is required" >&2
  exit 1
fi

if ! command -v restic >/dev/null 2>&1; then
  echo "Warning: restic is not currently installed. Install it before starting the service." >&2
  echo "  Arch:   sudo pacman -S restic" >&2
  echo "  Ubuntu: sudo apt install restic" >&2
fi

echo "Installing ${SERVICE_NAME} from ${SCRIPT_DIR}"

sudo_run install -d -m 700 "$RESTIC_DIR"

sudo_run install -m 700 "$SCRIPT_SRC" "$SCRIPT_DST"
sudo_run install -m 700 "$RESTORE_SRC" "$RESTORE_DST"
sudo_run install -m 644 "$SERVICE_SRC" "$SERVICE_DST"
sudo_run install -m 644 "$TIMER_SRC" "$TIMER_DST"

# Exclusions are non-secret policy and are intentionally updated on every install.
sudo_run install -m 644 "$EXCLUDES_SRC" "$EXCLUDES_DST"

# Always install/update the non-secret example file.
sudo_run install -m 600 "$ENV_TEMPLATE_SRC" "$ENV_EXAMPLE_DST"

# Create the real env file only if it does not exist, so real R2 credentials are not overwritten.
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Would create ${ENV_DST} from template only if missing."
elif sudo test -f "$ENV_DST"; then
  echo "Keeping existing ${ENV_DST}"
else
  sudo install -m 600 "$ENV_TEMPLATE_SRC" "$ENV_DST"
  echo "Created ${ENV_DST} from template. Edit it with:"
  echo "  sudoedit ${ENV_DST}"
fi

# Generate a Restic repository password only if missing. This is the encryption key for your backups.
if [[ "$GENERATE_PASSWORD" -eq 1 ]]; then
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "Would generate ${PASSWORD_DST} only if missing."
  elif sudo test -f "$PASSWORD_DST"; then
    echo "Keeping existing ${PASSWORD_DST}"
  else
    sudo_shell "umask 077; openssl rand -base64 48 > '${PASSWORD_DST}'"
    sudo chmod 600 "$PASSWORD_DST"
    echo "Generated ${PASSWORD_DST}"
    echo "IMPORTANT: store this password in your password manager. Without it, restores are impossible."
    echo "View it once with:"
    echo "  sudo cat ${PASSWORD_DST}"
  fi
else
  echo "Skipped password generation. Ensure ${PASSWORD_DST} exists and is chmod 600 before starting the service."
fi

sudo_run systemctl daemon-reload

# Verify unit syntax if systemd-analyze is available.
if command -v systemd-analyze >/dev/null 2>&1; then
  sudo_run systemd-analyze verify "$SERVICE_DST" "$TIMER_DST"
fi

if [[ "$ENABLE_TIMER" -eq 1 ]]; then
  echo "Enabling timer ${SERVICE_NAME}.timer"
  sudo_run systemctl enable --now "${SERVICE_NAME}.timer"
else
  echo "Timer not enabled. Enable it later with:"
  echo "  sudo systemctl enable --now ${SERVICE_NAME}.timer"
fi

echo
echo "Installed R2 backup service files."
echo
echo "Next steps:"
echo "  1. Edit R2 credentials/config:"
echo "     sudoedit ${ENV_DST}"
echo "  2. Make sure ${PASSWORD_DST} is saved in your password manager."
echo "  3. Run one backup manually:"
echo "     sudo systemctl start ${SERVICE_NAME}.service"
echo "  4. Watch logs:"
echo "     sudo journalctl -u ${SERVICE_NAME}.service -f"
echo "  5. Enable automatic daily backups if not already enabled:"
echo "     sudo systemctl enable --now ${SERVICE_NAME}.timer"
echo "  6. List or restore snapshots:"
echo "     sudo restic-r2-restore list"
echo "     sudo restic-r2-restore restore latest /mnt/restic-restore --verify"
