#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NFS_BOOT="${ROOT_DIR}/nfs/rpi5-root/boot/firmware"
TFTP_BOOT="${ROOT_DIR}/assets/rpi5-tftp"
REMOTE_SCRIPT="/tmp/pex-enable-overlayfs.sh"

usage() {
  cat <<'USAGE'
Usage: scripts/enable-overlayfs.sh --pi-host USER@ADDRESS

Converts the running Pi's NFS root to a read-only OverlayFS lower layer with a
RAM-backed, disposable upper layer. Run this on the boot server while the Pi is
booted and reachable over SSH.

Example:
  scripts/enable-overlayfs.sh --pi-host zijian@192.168.8.50
USAGE
}

install_on_pi() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "The Pi-side installation must run as root." >&2
    exit 1
  fi

  if ! grep -qw 'root=/dev/nfs' /proc/cmdline; then
    echo "This Pi is not currently using an NFS root." >&2
    exit 1
  fi

  for command_name in update-initramfs findmnt mount; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
      echo "Missing required Pi command: ${command_name}" >&2
      exit 1
    fi
  done

  local kernel
  kernel="$(uname -r)"
  if [[ ! -d "/lib/modules/${kernel}" ]]; then
    echo "Kernel modules for ${kernel} are missing." >&2
    exit 1
  fi

  install -d -m 0755 /etc/initramfs-tools/scripts/nfs-bottom
  install -m 0755 /dev/stdin /etc/initramfs-tools/scripts/nfs-bottom/pex-overlay <<'OVERLAY'
#!/bin/sh
set -e

PREREQ=""
prereqs() {
  echo "${PREREQ}"
}

case "${1:-}" in
  prereqs)
    prereqs
    exit 0
    ;;
esac

. /scripts/functions

case " $(cat /proc/cmdline) " in
  *" pex.overlay=tmpfs "*) ;;
  *) exit 0 ;;
esac

mkdir -p /lower /overlay-tmpfs "${rootmnt}"

# The NFS root has already been mounted by initramfs-tools. Protect the base
# image, move it aside as the lower layer, then put a RAM overlay at rootmnt.
mount -o remount,ro "${rootmnt}"
mount --move "${rootmnt}" /lower
mount -t tmpfs -o mode=0755,nodev,nosuid tmpfs /overlay-tmpfs
mkdir -p /overlay-tmpfs/upper /overlay-tmpfs/work

modprobe overlay
mount -t overlay overlay \
  -o lowerdir=/lower,upperdir=/overlay-tmpfs/upper,workdir=/overlay-tmpfs/work \
  "${rootmnt}"
OVERLAY

  if ! grep -qxF overlay /etc/initramfs-tools/modules; then
    printf '%s\n' overlay >> /etc/initramfs-tools/modules
  fi

  if [[ -f "/boot/firmware/cmdline.txt" ]]; then
    local cmdline=/boot/firmware/cmdline.txt
    local config=/boot/firmware/config.txt
  else
    local cmdline=/boot/cmdline.txt
    local config=/boot/config.txt
  fi

  if ! grep -qw 'pex.overlay=tmpfs' "${cmdline}"; then
    sed -i '1 s/$/ pex.overlay=tmpfs/' "${cmdline}"
  fi

  update-initramfs -c -k "${kernel}" 2>/dev/null || update-initramfs -u -k "${kernel}"

  local initrd_name="initrd.img-${kernel}-pex-overlay"
  cp -f "/boot/initrd.img-${kernel}" "$(dirname "${config}")/${initrd_name}"
  sed -i '/^initramfs .*pex-overlay.* followkernel$/d' "${config}"
  printf 'initramfs %s followkernel\n' "${initrd_name}" >> "${config}"

  sync
  echo "Pi-side OverlayFS initramfs created for ${kernel}."
}

if [[ "${1:-}" == "--install-on-pi" ]]; then
  install_on_pi
  exit 0
fi

PI_HOST=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pi-host)
      PI_HOST="${2:?missing value for --pi-host}"
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

if [[ -z "${PI_HOST}" ]]; then
  echo "--pi-host is required." >&2
  usage >&2
  exit 2
fi

if [[ ! -d "${NFS_BOOT}" || ! -d "${TFTP_BOOT}" ]]; then
  echo "Prepared NFS and TFTP boot trees were not found." >&2
  exit 1
fi

for command_name in ssh scp rsync; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "Missing required server command: ${command_name}" >&2
    exit 1
  fi
done

echo "Installing the NFS OverlayFS initramfs on ${PI_HOST}..."
scp "$0" "${PI_HOST}:${REMOTE_SCRIPT}"
ssh -t "${PI_HOST}" "sudo bash '${REMOTE_SCRIPT}' --install-on-pi"
ssh "${PI_HOST}" "rm -f '${REMOTE_SCRIPT}'"

BACKUP_DIR="${ROOT_DIR}/work/overlayfs-backups/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "${BACKUP_DIR}"
cp -a "${TFTP_BOOT}/cmdline.txt" "${TFTP_BOOT}/config.txt" "${BACKUP_DIR}/"

echo "Synchronizing the updated initramfs and boot configuration to TFTP..."
if [[ -w "${TFTP_BOOT}" ]]; then
  rsync -a "${NFS_BOOT}/" "${TFTP_BOOT}/"
elif command -v sudo >/dev/null 2>&1; then
  sudo rsync -a "${NFS_BOOT}/" "${TFTP_BOOT}/"
else
  echo "Cannot update ${TFTP_BOOT}; rerun as root or install sudo." >&2
  exit 1
fi

if ! grep -qw 'pex.overlay=tmpfs' "${TFTP_BOOT}/cmdline.txt"; then
  echo "OverlayFS kernel option did not reach the TFTP boot tree." >&2
  exit 1
fi

if ! grep -q '^initramfs .*pex-overlay.* followkernel$' "${TFTP_BOOT}/config.txt"; then
  echo "OverlayFS initramfs entry did not reach the TFTP boot tree." >&2
  exit 1
fi

echo
echo "OverlayFS is enabled and the previous boot configuration is backed up at:"
echo "  ${BACKUP_DIR}"
echo "Reboot the Pi, then verify with: findmnt -t overlay /"
echo "Changes made after reboot will be discarded on the following reboot."
