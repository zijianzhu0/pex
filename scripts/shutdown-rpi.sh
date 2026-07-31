#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/shutdown-rpi.sh --pi-host USER@ADDRESS [--no-wait]

Safely powers off a network-booted Raspberry Pi over SSH from the boot server.

Example:
  scripts/shutdown-rpi.sh --pi-host zijian@192.168.8.50
USAGE
}

PI_HOST=""
WAIT_FOR_POWER_OFF=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pi-host)
      PI_HOST="${2:?missing value for --pi-host}"
      shift 2
      ;;
    --no-wait)
      WAIT_FOR_POWER_OFF=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "${PI_HOST}" ]]; then
  echo "--pi-host is required." >&2
  usage >&2
  exit 2
fi

if ! command -v ssh >/dev/null 2>&1; then
  echo "SSH is required. Run scripts/install-dependencies.sh first." >&2
  exit 1
fi

echo "Checking SSH access and sudo permission on ${PI_HOST}..."
ssh -t -o ConnectTimeout=10 "${PI_HOST}" "sudo -v"

echo "Requesting a clean shutdown of ${PI_HOST}..."
set +e
ssh -t -o ConnectTimeout=10 "${PI_HOST}" \
  "sudo systemctl poweroff"
ssh_status=$?
set -e

# SSH commonly exits with 255 because the Pi drops the connection while
# powering off. Other failures generally mean the shutdown command never ran.
if [[ "${ssh_status}" -ne 0 && "${ssh_status}" -ne 255 ]]; then
  echo "The shutdown command failed with SSH status ${ssh_status}." >&2
  exit "${ssh_status}"
fi

if [[ "${WAIT_FOR_POWER_OFF}" -eq 0 ]]; then
  echo "Shutdown requested."
  exit 0
fi

if ! command -v ping >/dev/null 2>&1; then
  echo "Shutdown requested; ping is unavailable, so power-off was not verified."
  exit 0
fi

PI_ADDRESS="${PI_HOST#*@}"
PI_ADDRESS="${PI_ADDRESS#\[}"
PI_ADDRESS="${PI_ADDRESS%\]}"

echo "Waiting up to 60 seconds for ${PI_ADDRESS} to stop responding..."
for ((attempt = 1; attempt <= 30; attempt++)); do
  if ! ping -c 1 -W 1 "${PI_ADDRESS}" >/dev/null 2>&1; then
    echo "The Pi is offline. It is safe to remove power."
    exit 0
  fi
  sleep 2
done

echo "The Pi still responds after 60 seconds; check it before removing power." >&2
exit 1
