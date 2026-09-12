#!/usr/bin/env bash
# Тест разметки диска из sg-install-run БЕЗ root/VirtualBox.
# Эмулирует реальный сценарий: файл-диск со СТАРОЙ GPT-разметкой и остатками
# предыдущей неудачной установки (ровно как в VirtualBox после падения).
#
# Запуск: bash tests/test-install-disk.sh
# Результат: PASS/FAIL + краткая таблица разделов.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="$ROOT_DIR/archiso/airootfs/usr/local/bin/sg-install-run"
DISK=/tmp/sg-test-disk.img
SIZE_MIB=2048
PASS_CNT=0
FAIL_CNT=0

ok()   { PASS_CNT=$((PASS_CNT+1)); echo "  ✓ $1"; }
bad()  { FAIL_CNT=$((FAIL_CNT+1)); echo "  ✗ $1"; }
run_case() {
  local name="$1"; shift
  echo "— $name"
  if "$@" >> /tmp/sg-test-run.log 2>&1; then return 0; else return 1; fi
}

need() { command -v "$1" >/dev/null 2>&1 || { echo "нет утилиты: $1 (apt-get install $2)"; exit 2; }; }
need sfdisk fdisk
need parted parted
need wipefs util-linux

# Установщик вызывает mkfs/mount на реальном пути — в тесте до них не доходит
# (TEST_MODE выходит после проверки таблицы), так что они не нужны.

echo "== Тест разметки sg-install-run (виртуальный диск-файл) =="

make_dirty_disk() {
  # Диск со СТАРОЙ GPT + старыми разделами + мусорной ФС — как после
  # неудачной установки в VirtualBox.
  rm -f "$DISK"
  truncate -s "${SIZE_MIB}M" "$DISK"
  parted -s "$DISK" mklabel gpt \
    && parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB \
    && parted -s "$DISK" mkpart root ext4 513MiB 100% >/dev/null 2>&1
  # грязные подписи в начале разделов
  printf 'FAT32-OLD' | dd of="$DISK" bs=1 seek=$((2048*512)) conv=notrunc status=none
  printf 'EXT4-OLD\x00\x00\x00' | dd of="$DISK" bs=1 seek=$((514*1024*1024)) conv=notrunc status=none
  sync
}

make_mbr_disk() {
  rm -f "$DISK"
  truncate -s "${SIZE_MIB}M" "$DISK"
  parted -s "$DISK" mklabel msdos \
    && parted -s "$DISK" mkpart primary ext4 1MiB 100% >/dev/null 2>&1
  sync
}

run_installer() {
  local conf; conf=$(mktemp /tmp/sg-test-conf.XXXXXX)
  printf "DISK='%s'\nHOSTNAME='testvm'\nUSERNAME='tester'\nPASS='test1234'\nSWAP_GB='2'\nWINE='0'\n" "$DISK" > "$conf"
  chmod 600 "$conf"
  SG_INSTALL_TEST=1 bash "$INSTALLER" "$conf"
}

echo
echo "1) Диск со старой GPT-разметкой (твой сценарий)"
make_dirty_disk
if run_case "sg-install-run TEST" run_installer; then
  ok "установщик прошёл разметку"
  sfdisk -d "$DISK" 2>/dev/null | grep -q "C12A7328" && ok "ESP (type EFI) на месте" || bad "нет ESP"
  sfdisk -d "$DISK" 2>/dev/null | grep -q "0FC63DAF" && ok "root (type Linux) на месте" || bad "нет root"
  grep -q "ТЕСТ ПРОЙДЕН" /tmp/sg-install.log && ok "лог: ТЕСТ ПРОЙДЕН" || bad "лог без ТЕСТ ПРОЙДЕН"
else
  bad "установщик упал — хвост лога:"
  tail -n 15 /tmp/sg-install.log
fi

echo
echo "2) Диск с MBR (не-GPT разметка)"
make_mbr_disk
if run_case "sg-install-run TEST" run_installer; then
  ok "MBR перезаписан на GPT"
else
  bad "упал на MBR-диске"; tail -n 15 /tmp/sg-install.log
fi

echo
echo "3) Полностью нулевой диск (новый VDI)"
rm -f "$DISK"; truncate -s "${SIZE_MIB}M" "$DISK"
if run_case "sg-install-run TEST" run_installer; then
  ok "разметка на пустом диске"
else
  bad "упал на пустом диске"; tail -n 15 /tmp/sg-install.log
fi

echo
echo "4) Крошечный диск (должен отказаться с внятной ошибкой)"
rm -f "$DISK"; truncate -s 512M "$DISK"
OUT=$(run_installer 2>&1); RC=$?
if [[ $RC -ne 0 ]] && grep -q "слишком маленький" /tmp/sg-install.log; then
  ok "отказ на маленьком диске с сообщением"
else
  bad "не отказался или неверное сообщение (rc=$RC)"; grep ERROR /tmp/sg-install.log
fi

echo
echo "== Итог: PASS=$PASS_CNT FAIL=$FAIL_CNT =="
rm -f "$DISK"
[[ $FAIL_CNT -eq 0 ]]