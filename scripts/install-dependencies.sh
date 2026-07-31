#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This installer supports Linux hosts only." >&2
  exit 1
fi

if [[ "${EUID}" -eq 0 ]]; then
  AS_ROOT=()
elif command -v sudo >/dev/null 2>&1; then
  AS_ROOT=(sudo)
else
  echo "Run this script as root, or install sudo first." >&2
  exit 1
fi

echo "Installing Raspberry Pi network-boot tools..."

if command -v apt-get >/dev/null 2>&1; then
  "${AS_ROOT[@]}" apt-get update
  "${AS_ROOT[@]}" apt-get install -y \
    ca-certificates curl xz-utils util-linux dosfstools mtools rsync \
    docker.io nfs-kernel-server
  if apt-cache show docker-compose-v2 >/dev/null 2>&1; then
    "${AS_ROOT[@]}" apt-get install -y docker-compose-v2
  elif apt-cache show docker-compose-plugin >/dev/null 2>&1; then
    "${AS_ROOT[@]}" apt-get install -y docker-compose-plugin
  else
    "${AS_ROOT[@]}" apt-get install -y docker-compose
  fi
elif command -v dnf >/dev/null 2>&1; then
  "${AS_ROOT[@]}" dnf install -y \
    ca-certificates curl xz util-linux dosfstools mtools rsync \
    docker docker-compose-plugin nfs-utils
elif command -v pacman >/dev/null 2>&1; then
  "${AS_ROOT[@]}" pacman -Syu --needed --noconfirm \
    ca-certificates curl xz util-linux dosfstools mtools rsync \
    docker docker-compose nfs-utils
elif command -v apk >/dev/null 2>&1; then
  "${AS_ROOT[@]}" apk add \
    ca-certificates curl xz util-linux dosfstools mtools rsync \
    docker docker-cli-compose nfs-utils
else
  echo "Unsupported package manager. Use apt, dnf, pacman, or apk." >&2
  exit 1
fi

if command -v systemctl >/dev/null 2>&1; then
  "${AS_ROOT[@]}" systemctl enable --now docker
elif command -v rc-update >/dev/null 2>&1; then
  "${AS_ROOT[@]}" rc-update add docker default
  "${AS_ROOT[@]}" rc-service docker start
fi

# Let future logins use Docker without sudo. The current shell may still need
# `newgrp docker`, so image pulls below fall back to sudo when necessary.
if [[ "${EUID}" -ne 0 ]] && getent group docker >/dev/null 2>&1; then
  "${AS_ROOT[@]}" usermod -aG docker "${USER}"
fi

required_commands=(
  curl sha256sum xz sfdisk mkfs.vfat mcopy rsync
  losetup mount umount mountpoint docker
)

missing=()
for command_name in "${required_commands[@]}"; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    missing+=("${command_name}")
  fi
done

if ((${#missing[@]})); then
  echo "Installation finished, but these commands are still missing: ${missing[*]}" >&2
  exit 1
fi

if docker info >/dev/null 2>&1; then
  DOCKER=()
elif "${AS_ROOT[@]}" docker info >/dev/null 2>&1; then
  DOCKER=("${AS_ROOT[@]}")
else
  echo "Docker was installed, but its daemon is not available." >&2
  exit 1
fi

if "${DOCKER[@]}" docker compose version >/dev/null 2>&1; then
  COMPOSE=("${DOCKER[@]}" docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE=("${DOCKER[@]}" docker-compose)
else
  echo "Docker Compose was installed but could not be started." >&2
  exit 1
fi

echo "Downloading the container images declared in docker-compose.yml..."
"${COMPOSE[@]}" -f "${ROOT_DIR}/docker-compose.yml" pull

echo
echo "All tools, host packages, and container images are installed."
if [[ "${EUID}" -ne 0 ]] && ! docker info >/dev/null 2>&1; then
  echo "Log out and back in before running Docker without sudo."
fi
echo "Next: ${ROOT_DIR}/scripts/prepare-rpi5-lite.sh"
