# Raspberry Pi 5 LAN Boot Workspace

This folder prepares the local files needed for a Raspberry Pi 5 network boot.
Networking/DHCP/NFS service wiring is intentionally separate.

The smallest practical base here is the official Raspberry Pi OS Legacy Lite
64-bit image. It is smaller than the current Trixie Lite image and is listed by
Raspberry Pi as compatible with Raspberry Pi 5.

## What Was Enabled On This Machine

This workspace has been prepared as a Raspberry Pi 5 LAN boot server.

- Downloaded and verified the official Raspberry Pi OS Legacy Lite 64-bit
  image:
  `downloads/raspios-bookworm-arm64-lite.img.xz`
- Extracted the image into:
  - `assets/rpi5-tftp/` for Raspberry Pi firmware and kernel files served by
    TFTP
  - `nfs/rpi5-root/` for the root filesystem that the Pi mounts over NFS
- Generated `assets/rpi5-tftp/cmdline.txt` so the Pi boots with:

```text
nfsroot=192.168.8.187:/home/zijian/repositories/pex/nfs/rpi5-root,vers=3,tcp,nolock
```

- Created `assets/rpi5-boot.img`, a compact FAT boot image from the TFTP tree.
  The current manifest says it was created at `2026-05-31T06:12:41Z`.
- Added `docker-compose.yml` with a `rpi5-tftp` service. It runs
  `dnsmasq` from the `ghcr.io/netbootxyz/netbootxyz` image in host network
  mode, disables DNS with `--port=0`, enables TFTP, and serves
  `./assets/rpi5-tftp` from `/tftp`.
- Started the `rpi5-tftp` container. Current check:

```bash
docker ps --filter name=rpi5-tftp
```

The service is bound to interface `enp2s0` in `docker-compose.yml`.

NFS is expected to export:

```text
/home/zijian/repositories/pex/nfs/rpi5-root
```

The Pi boot command already points there. If NFS needs to be recreated on a
fresh host, add an export for that path and reload the NFS server.

## Prepare Files

Run:

```bash
./scripts/prepare-rpi5-lite.sh
```

That creates:

```text
assets/rpi5-tftp/        # boot partition files for TFTP
assets/rpi5-boot.img     # compact FAT boot ramdisk image, if it fits under 96 MiB
nfs/rpi5-root/           # root filesystem tree for NFS
config/rpi5/cmdline.txt.template
```

When you know the LAN server IP and NFS export path, regenerate the boot command
line:

```bash
./scripts/prepare-rpi5-lite.sh --server-ip 192.168.1.10 --root-export /srv/rpi5-root
```

The resulting `assets/rpi5-tftp/cmdline.txt` will point the Pi kernel at the
NFS root.

## Notes

- Raspberry Pi 5 requires a non-empty `config.txt` in the boot filesystem.
- `boot.img` is optional. It is useful because the Pi firmware can load one FAT
  boot image instead of many individual TFTP files. The Raspberry Pi bootloader
  limits this image to 96 MiB.
- The root filesystem is not an SD-card image after extraction. It is a normal
  directory intended to be exported by NFS later.
