#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TFTP_BOOT="${ROOT_DIR}/assets/rpi5-tftp"
NFS_BOOT="${ROOT_DIR}/nfs/rpi5-root/boot/firmware"
NFS_ROOT="${ROOT_DIR}/nfs/rpi5-root"

usage() {
  cat <<'USAGE'
Usage: scripts/customize-rpi-user.sh [--username NAME]

Securely prompts for a password, configures the first Raspberry Pi OS account,
and enables SSH. Run this after scripts/prepare-rpi5-lite.sh.
USAGE
}

USERNAME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --username)
      USERNAME="${2:?missing value for --username}"
      shift 2
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

if [[ ! -d "${TFTP_BOOT}" || ! -d "${NFS_BOOT}" ]]; then
  echo "Prepared boot files were not found." >&2
  echo "Run scripts/prepare-rpi5-lite.sh first." >&2
  exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "OpenSSL is required. Run scripts/install-dependencies.sh first." >&2
  exit 1
fi

if [[ ! -x "${NFS_ROOT}/usr/sbin/sshd" ]]; then
  echo "OpenSSH Server is not present in the extracted Pi root." >&2
  echo "The official Raspberry Pi OS Lite image normally includes it." >&2
  exit 1
fi

if [[ -z "${USERNAME}" ]]; then
  read -r -p "Raspberry Pi username: " USERNAME
fi

if [[ ! "${USERNAME}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
  echo "Invalid username. Use up to 32 lowercase letters, digits, _ or -." >&2
  exit 1
fi

echo "Enter the password for ${USERNAME}. It will not be displayed."
PASSWORD_HASH="$(openssl passwd -6)"
trap 'unset PASSWORD_HASH' EXIT

write_file() {
  local path="$1"
  local content="$2"

  if [[ -w "$(dirname "${path}")" ]]; then
    printf '%s\n' "${content}" > "${path}"
    chmod 600 "${path}"
  elif command -v sudo >/dev/null 2>&1; then
    printf '%s\n' "${content}" | sudo tee "${path}" >/dev/null
    sudo chmod 600 "${path}"
  else
    echo "Cannot write ${path}; rerun as root or install sudo." >&2
    exit 1
  fi
}

enable_ssh_marker() {
  local path="$1"

  if [[ -w "$(dirname "${path}")" ]]; then
    : > "${path}"
  elif command -v sudo >/dev/null 2>&1; then
    sudo touch "${path}"
  else
    echo "Cannot write ${path}; rerun as root or install sudo." >&2
    exit 1
  fi
}

ACCOUNT="${USERNAME}:${PASSWORD_HASH}"
write_file "${TFTP_BOOT}/userconf.txt" "${ACCOUNT}"
write_file "${NFS_BOOT}/userconf.txt" "${ACCOUNT}"
enable_ssh_marker "${TFTP_BOOT}/ssh"
enable_ssh_marker "${NFS_BOOT}/ssh"

echo
echo "Configured Raspberry Pi user '${USERNAME}' and enabled SSH."
echo "Boot the Pi, then connect with: ssh ${USERNAME}@<pi-ip-address>"
