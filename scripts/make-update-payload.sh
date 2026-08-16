#!/usr/bin/env bash
# safegamingOS — собрать слой обновления (файлы safegamingOS поверх Arch)
# для автообновления: out/safegamingos-files-<VER>.tar.zst
#
# Usage: bash scripts/make-update-payload.sh <VER> [OUT_DIR]
# (запускается из корня репозитория; в CI — из workflow build-iso.yml)
set -euo pipefail

VER="${1:?version required, e.g. 0.11.0}"
OUT="${2:-out}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

mkdir -p "${OUT}"
STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT
mkdir -p "${STAGE}/usr/share/safegamingos"
printf '%s\n' "${VER}" > "${STAGE}/usr/share/safegamingos/version"

PAY="${OUT}/safegamingos-files-${VER}.tar.zst"
rm -f "${PAY}"

# Слой safegamingOS = ровно те файлы, что инсталлятор кладёт поверх Arch
# (шаг «Копирование брендинга» в sg-install-run) + служебные юниты/конфиги.
tar --zstd -cf "${PAY}" \
  -C archiso/airootfs \
  usr/local/bin \
  usr/local/lib/sg-rooms \
  usr/share/safegamingos \
  usr/share/plymouth/themes/safegamingos \
  usr/share/wallpapers \
  usr/share/color-schemes/safegamingOS.colors \
  usr/share/konsole \
  usr/share/applications/safegamingos-gui.desktop \
  usr/share/applications/sg-browser.desktop \
  usr/share/applications/sg-games.desktop \
  usr/share/applications/sg-streaming.desktop \
  etc/skel \
  etc/polkit-1 \
  etc/sysctl.d/99-safegamingos.conf \
  etc/nftables.conf \
  etc/firefox \
  usr/lib/systemd/system/sg-av-scan.service \
  usr/lib/systemd/system/sg-av-scan.timer \
  usr/lib/systemd/system/sg-track.service \
  usr/lib/systemd/system/sg-watch.service \
  usr/share/sddm/themes/breeze/theme.conf.user \
  -C "${STAGE}" \
  usr/share/safegamingos/version

echo "payload: ${PAY}"
ls -lh "${PAY}"
