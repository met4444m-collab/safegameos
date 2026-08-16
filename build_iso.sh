#!/usr/bin/env bash
#
# safegamingOS — build the bootable ISO with mkarchiso.
#
# Requirements (run this ON an Arch Linux machine, or inside an archlinux
# container/VM with the archiso package):
#   sudo pacman -S archiso
#
# Usage:
#   sudo ./build_iso.sh            # builds out/safegamingos-<ver>-x86_64.iso
#
set -euo pipefail
cd "$(dirname "$0")"

ISO_VERSION="0.9.5"

if [[ ${EUID} -ne 0 ]]; then
  echo ":: must be run as root (mkarchiso needs root)" >&2
  exit 1
fi

if ! command -v mkarchiso >/dev/null 2>&1; then
  echo ":: 'mkarchiso' not found — install it first:" >&2
  echo "     sudo pacman -S archiso" >&2
  exit 1
fi

if [[ -f /etc/os-release ]]; then
  if ! grep -qi "arch" /etc/os-release; then
    echo ":: warning: not running on Arch Linux — mkarchiso may still work" \
      "inside an Arch container, but results are not guaranteed." >&2
  fi
fi

rm -rf out work
mkdir -p out

echo ":: building safegamingOS ${ISO_VERSION} ISO (this takes a while)…"
mkarchiso -v -w "$(pwd)/work" -o "$(pwd)/out" "$(pwd)/archiso"

rm -rf work
ISO="$(ls out/*.iso 2>/dev/null | head -n1)"
if [[ -n "${ISO}" ]]; then
  echo
  echo ":: done: ${ISO}"
  echo ":: write to USB:   sudo dd bs=4M if=\"${ISO}\" of=/dev/sdX status=progress oflag=sync"
  echo ":: or use Ventoy / balenaEtcher."
else
  echo ":: build finished but no ISO found in out/ — check mkarchiso output." >&2
  exit 1
fi
