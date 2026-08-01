#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

IMAGE_URL="https://downloads.raspberrypi.com/raspios_oldstable_lite_arm64/images/raspios_oldstable_lite_arm64-2026-04-14/2026-04-13-raspios-bookworm-arm64-lite.img.xz"
IMAGE_SHA256="9bba9c625dd4dd4e1b326dd2551e37a2029db9090bf19ea300649b78c054de6f"
IMAGE_XZ="${ROOT_DIR}/downloads/raspios-bookworm-arm64-lite.img.xz"
IMAGE_RAW="${ROOT_DIR}/work/raspios-bookworm-arm64-lite.img"

TFTP_DIR="${ROOT_DIR}/assets/rpi5-tftp"
BOOT_IMG="${ROOT_DIR}/assets/rpi5-boot.img"
NFS_ROOT="${ROOT_DIR}/nfs/rpi5-root"
CONFIG_DIR="${ROOT_DIR}/config/rpi5"

SERVER_IP=""
ROOT_EXPORT="/srv/rpi5-root"
BOOT_IMG_SIZE_MIB=96

usage() {
  cat <<'USAGE'
Usage: scripts/prepare-rpi5-lite.sh [options]

Options:
  --server-ip IP          LAN IP that will export the NFS root later
  --root-export PATH     NFS export path the Pi should mount later
                          default: /srv/rpi5-root
  --no-download          Require the compressed image to already exist
  -h, --help             Show this help

Outputs:
  assets/rpi5-tftp/
  assets/rpi5-boot.img, if the boot tree fits under 96 MiB
  nfs/rpi5-root/
  config/rpi5/cmdline.txt.template
USAGE
}

NO_DOWNLOAD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-ip)
      SERVER_IP="${2:?missing value for --server-ip}"
      shift 2
      ;;
    --root-export)
      ROOT_EXPORT="${2:?missing value for --root-export}"
      shift 2
      ;;
    --no-download)
      NO_DOWNLOAD=1
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

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

need curl
need sha256sum
need xz
need sfdisk
need mkfs.vfat
need mcopy
need stat

HAVE_SUDO=0
AS_ROOT=()
if [[ "${EUID}" -eq 0 ]]; then
  HAVE_SUDO=1
elif command -v sudo >/dev/null 2>&1; then
  echo "Root access is required to preserve Raspberry Pi OS file ownership."
  if sudo -v; then
    AS_ROOT=(sudo)
    HAVE_SUDO=1
  fi
fi

if [[ "${HAVE_SUDO}" -eq 1 ]]; then
  need losetup
  need mount
  need umount
  need rsync
else
  need docker
fi

mkdir -p "${ROOT_DIR}/downloads" "${ROOT_DIR}/work" "${TFTP_DIR}" "${NFS_ROOT}" "${CONFIG_DIR}"

if [[ ! -f "${IMAGE_XZ}" ]]; then
  if [[ "${NO_DOWNLOAD}" -eq 1 ]]; then
    echo "Image is missing: ${IMAGE_XZ}" >&2
    exit 1
  fi
  echo "Downloading Raspberry Pi OS Legacy Lite 64-bit..."
  curl -L --fail --output "${IMAGE_XZ}" "${IMAGE_URL}"
fi

echo "${IMAGE_SHA256}  ${IMAGE_XZ}" | sha256sum --check -

if [[ ! -f "${IMAGE_RAW}" || "${IMAGE_XZ}" -nt "${IMAGE_RAW}" ]]; then
  echo "Decompressing image..."
  xz -dkc "${IMAGE_XZ}" > "${IMAGE_RAW}"
fi

partition_start_size() {
  local part="$1"
  sfdisk -d "${IMAGE_RAW}" | awk -v suffix="${part}" '
    $1 ~ suffix "$" {
      gsub(",", "")
      for (i = 1; i <= NF; i++) {
        if ($i == "start=") start = $(i + 1)
        if ($i == "size=") size = $(i + 1)
      }
      print start, size
    }
  '
}

read -r BOOT_START BOOT_SIZE < <(partition_start_size 1)
read -r ROOT_START ROOT_SIZE < <(partition_start_size 2)

if [[ -z "${BOOT_START:-}" || -z "${ROOT_START:-}" ]]; then
  echo "Could not read partition offsets from ${IMAGE_RAW}" >&2
  exit 1
fi

if [[ "${HAVE_SUDO}" -eq 1 ]]; then
  LOOP_DEV=""
  BOOT_MNT="${ROOT_DIR}/work/mnt-boot"
  ROOT_MNT="${ROOT_DIR}/work/mnt-root"

  cleanup() {
    set +e
    if mountpoint -q "${BOOT_MNT}"; then
      "${AS_ROOT[@]}" umount "${BOOT_MNT}"
    fi
    if mountpoint -q "${ROOT_MNT}"; then
      "${AS_ROOT[@]}" umount "${ROOT_MNT}"
    fi
    if [[ -n "${LOOP_DEV}" ]]; then
      "${AS_ROOT[@]}" losetup -d "${LOOP_DEV}"
    fi
  }
  trap cleanup EXIT

  mkdir -p "${BOOT_MNT}" "${ROOT_MNT}"

  echo "Attaching image with elevated privileges..."
  LOOP_DEV="$("${AS_ROOT[@]}" losetup --find --show --partscan "${IMAGE_RAW}")"

  "${AS_ROOT[@]}" mount -o ro "${LOOP_DEV}p1" "${BOOT_MNT}"
  "${AS_ROOT[@]}" mount -o ro "${LOOP_DEV}p2" "${ROOT_MNT}"

  echo "Copying TFTP boot files..."
  "${AS_ROOT[@]}" rsync -a --delete "${BOOT_MNT}/" "${TFTP_DIR}/"
else
  BOOT_OFFSET=$((BOOT_START * 512))
  BOOT_LIMIT=$((BOOT_SIZE * 512))
  ROOT_OFFSET=$((ROOT_START * 512))

  echo "Extracting image with a privileged Docker helper..."
  docker run --rm --privileged \
    -e BOOT_OFFSET="${BOOT_OFFSET}" \
    -e BOOT_LIMIT="${BOOT_LIMIT}" \
    -e ROOT_OFFSET="${ROOT_OFFSET}" \
    -v "${ROOT_DIR}:/work" \
    debian:bookworm-slim \
    bash -lc 'set -euo pipefail
      mkdir -p /mnt/boot /mnt/root /work/assets/rpi5-tftp /work/nfs/rpi5-root
      mount -o loop,ro,offset="${BOOT_OFFSET}",sizelimit="${BOOT_LIMIT}" /work/work/raspios-bookworm-arm64-lite.img /mnt/boot
      mount -o loop,ro,offset="${ROOT_OFFSET}" /work/work/raspios-bookworm-arm64-lite.img /mnt/root
      rm -rf /work/assets/rpi5-tftp/* /work/nfs/rpi5-root/*
      cp -a /mnt/boot/. /work/assets/rpi5-tftp/
      cp -a /mnt/root/. /work/nfs/rpi5-root/
      rm -rf /work/nfs/rpi5-root/boot/firmware/*
      mkdir -p /work/nfs/rpi5-root/boot/firmware
      cp -a /work/assets/rpi5-tftp/. /work/nfs/rpi5-root/boot/firmware/
      umount /mnt/root
      umount /mnt/boot'
fi

# The remaining boot files are generated by this unprivileged script. Make the
# staging tree writable temporarily, then restore root ownership before exit.
if [[ "${HAVE_SUDO}" -eq 1 ]]; then
  "${AS_ROOT[@]}" chown -R "$(id -u):$(id -g)" "${TFTP_DIR}"
else
  docker run --rm \
    -e HOST_UID="$(id -u)" \
    -e HOST_GID="$(id -g)" \
    -v "${ROOT_DIR}:/work" \
    debian:bookworm-slim \
    sh -c 'chown -R "${HOST_UID}:${HOST_GID}" /work/assets/rpi5-tftp'
fi

cat > "${CONFIG_DIR}/cmdline.txt.template" <<EOF
console=serial0,115200 console=tty1 root=/dev/nfs nfsroot=<server-ip>:${ROOT_EXPORT},vers=3,tcp,nolock rw ip=dhcp rootwait
EOF

if [[ -n "${SERVER_IP}" ]]; then
  sed "s/<server-ip>/${SERVER_IP}/" "${CONFIG_DIR}/cmdline.txt.template" > "${TFTP_DIR}/cmdline.txt"
else
  cp "${CONFIG_DIR}/cmdline.txt.template" "${TFTP_DIR}/cmdline.txt.template"
fi

if [[ ! -s "${TFTP_DIR}/config.txt" ]]; then
  printf '# Raspberry Pi 5 requires this file to be non-empty.\n' > "${TFTP_DIR}/config.txt"
fi

if [[ "${HAVE_SUDO}" -eq 1 ]]; then
  echo "Copying NFS root filesystem..."
  "${AS_ROOT[@]}" rsync -aHAX --numeric-ids --delete \
    --exclude '/boot/firmware/*' \
    "${ROOT_MNT}/" "${NFS_ROOT}/"

  "${AS_ROOT[@]}" mkdir -p "${NFS_ROOT}/boot/firmware"
  "${AS_ROOT[@]}" rsync -a "${TFTP_DIR}/" "${NFS_ROOT}/boot/firmware/"
else
  docker run --rm \
    -v "${ROOT_DIR}:/work" \
    debian:bookworm-slim \
    bash -lc 'set -euo pipefail
      rm -rf /work/nfs/rpi5-root/boot/firmware/*
      cp -a /work/assets/rpi5-tftp/. /work/nfs/rpi5-root/boot/firmware/'
fi

# The source image expects its root and boot partitions to be available by
# PARTUUID. This workspace supplies both from the NFS root instead, so leaving
# those entries in place makes systemd-remount-fs and boot-firmware.mount fail
# on the Pi.
echo "Configuring the NFS root filesystem table..."
if [[ "${HAVE_SUDO}" -eq 1 ]]; then
  printf 'proc\t/proc\tproc\tdefaults\t0\t0\n' | \
    "${AS_ROOT[@]}" tee "${NFS_ROOT}/etc/fstab" >/dev/null
  "${AS_ROOT[@]}" chown 0:0 "${NFS_ROOT}/etc/fstab"
  "${AS_ROOT[@]}" chmod 0644 "${NFS_ROOT}/etc/fstab"
else
  docker run --rm \
    -v "${ROOT_DIR}:/work" \
    debian:bookworm-slim \
    sh -c 'printf "proc\t/proc\tproc\tdefaults\t0\t0\n" > /work/nfs/rpi5-root/etc/fstab
      chown 0:0 /work/nfs/rpi5-root/etc/fstab
      chmod 0644 /work/nfs/rpi5-root/etc/fstab'
fi

echo "Creating compact boot.img if the boot tree fits..."
BOOT_BYTES="$(du -sb "${TFTP_DIR}" | awk '{print $1}')"
BOOT_LIMIT_BYTES=$((BOOT_IMG_SIZE_MIB * 1024 * 1024))
BOOT_OVERHEAD_BYTES=$((4 * 1024 * 1024))

if (( BOOT_BYTES + BOOT_OVERHEAD_BYTES < BOOT_LIMIT_BYTES )); then
  rm -f "${BOOT_IMG}"
  dd if=/dev/zero of="${BOOT_IMG}" bs=1M count="${BOOT_IMG_SIZE_MIB}" status=none
  mkfs.vfat -F 32 -n RPI5BOOT "${BOOT_IMG}" >/dev/null
  (cd "${TFTP_DIR}" && find . -mindepth 1 -maxdepth 1 -exec mcopy -s -i "${BOOT_IMG}" "{}" ::/ \;)
  {
    echo "source=${TFTP_DIR}"
    echo "size_mib=${BOOT_IMG_SIZE_MIB}"
    echo "created=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "${BOOT_IMG}.manifest"
else
  rm -f "${BOOT_IMG}" "${BOOT_IMG}.manifest"
  echo "Boot tree is larger than ${BOOT_IMG_SIZE_MIB} MiB; using directory TFTP only."
fi

# FAT does not store Unix owners, so make the server-side TFTP tree explicitly
# root-owned. Only the NFS root directory itself is normalized here: ownership
# below it must retain the numeric users and groups from the Raspberry Pi image.
echo "Normalizing prepared filesystem ownership..."
if [[ "${HAVE_SUDO}" -eq 1 ]]; then
  "${AS_ROOT[@]}" chown -R 0:0 "${TFTP_DIR}"
  "${AS_ROOT[@]}" chown 0:0 "${NFS_ROOT}"
else
  docker run --rm \
    -v "${ROOT_DIR}:/work" \
    debian:bookworm-slim \
    sh -c 'chown -R 0:0 /work/assets/rpi5-tftp && chown 0:0 /work/nfs/rpi5-root'
fi

if [[ "$(stat -c '%u:%g' "${TFTP_DIR}")" != "0:0" || \
      "$(stat -c '%u:%g' "${NFS_ROOT}/etc/passwd")" != "0:0" ]]; then
  echo "Prepared files are not owned by root; rootless Docker cannot preserve image ownership." >&2
  echo "Use privileged rootful Docker or rerun with working sudo access." >&2
  exit 1
fi

echo
echo "Prepared:"
echo "  ${TFTP_DIR}"
if [[ -f "${BOOT_IMG}" ]]; then
  echo "  ${BOOT_IMG}"
fi
echo "  ${NFS_ROOT}"
echo "  ${CONFIG_DIR}/cmdline.txt.template"
