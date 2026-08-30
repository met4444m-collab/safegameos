#!/bin/bash
# SafeGameOS bootstrap — downloads latest installer and runs it
set -e
BASE="https://raw.githubusercontent.com/met4444m-collab/safegameos/main/archiso/airootfs/usr/local/bin"
echo "==> Скачиваю SafeGameOS installer..."
curl -sLo /tmp/sg-install-run "$BASE/sg-install-run"
curl -sLo /tmp/sg-install "$BASE/sg-install"
curl -sLo /tmp/sg-install-gui "$BASE/sg-install-gui"
chmod +x /tmp/sg-install-run /tmp/sg-install /tmp/sg-install-gui
echo "==> Запускаю установщик..."
sudo /tmp/sg-install
