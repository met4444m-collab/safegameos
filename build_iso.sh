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

ISO_VERSION="0.11.1"

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

# ---------------------------------------------------------------------------
# Офлайн-набор для установки без интернета.
#
# ВАЖНО: набирается НА ХОСТЕ (build machine), а не внутри chroot: во время
# customize_airootfs.sh сети в chroot нет (pacstrap качает на хосте), поэтому
# `pacman -Sy` там мгновенно падал, набор молча не создавался, и НИ ОДИН ISO
# до v0.11.1 не содержал офлайн-установку. Здесь pacman работает (тот же
# контейнер только что качал пакеты), результат кладётся в
# archiso/airootfs/opt/sg-offline и попадает в ISO через overlay.
# ---------------------------------------------------------------------------
build_offline_bundle() {
  local dest="archiso/airootfs/opt/sg-offline"
  local expected have
  rm -rf "${dest}"
  mkdir -p "${dest}/db" "${dest}/pkgs"
  # shellcheck source=/dev/null
  source archiso/airootfs/usr/local/lib/sg-rooms/install-pkgs.conf
  echo ":: офлайн-набор: скачиваю базы репозиториев (свежий --dbpath)..."
  pacman -Sy --dbpath "${dest}/db" --cachedir "${dest}/pkgs" --noconfirm || exit 1
  expected="$(pacman -Sp --dbpath "${dest}/db" ${INSTALL_PKGS} 2>/dev/null | wc -l)"
  if [[ "${expected}" -lt 1 ]]; then
    echo ":: ОШИБКА: не удалось посчитать список пакетов установки (INSTALL_PKGS)." >&2
    exit 1
  fi
  echo ":: офлайн-набор: качаю ${expected} пакетов + зависимости (~2-3 ГБ)..."
  pacman -Sw --dbpath "${dest}/db" --cachedir "${dest}/pkgs" --noconfirm ${INSTALL_PKGS} || exit 1
  have="$(ls "${dest}/pkgs"/*.pkg.tar.* 2>/dev/null | wc -l)"
  if [[ "${have}" -lt "${expected}" ]]; then
    echo ":: ОШИБКА: офлайн-набор неполный (${have}/${expected}) — прерываю сборку." >&2
    exit 1
  fi
  cp -a /etc/pacman.d/gnupg "${dest}/gnupg"
  cp /etc/pacman.conf "${dest}/pacman.conf"
  cp /etc/pacman.d/mirrorlist "${dest}/mirrorlist" 2>/dev/null || true
  touch "${dest}/READY"
  echo ":: офлайн-набор готов: ${have} пакетов, $(du -sh "${dest}/pkgs" | cut -f1)"
}
build_offline_bundle

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
