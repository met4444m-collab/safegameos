# safegamingOS

Кастомная ОС на базе Arch Linux: изоляция приложений в «комнатах» (без тяжёлых VM), заточенная под игры и стримы (Minecraft, Roblox, OBS). При заражении комнаты антивирус SafeGuard предлагает удалить комнату либо вирус; изоляция не пускает заразу в другие комнаты, а источник загрузки (ссылка) запоминается и блокируется системно (можно разблокировать вручную).

## Что уже есть (база v0.9.0)

- **Собирается в загрузочный ISO** через `mkarchiso` (BIOS syslinux + UEFI systemd-boot).
- **Загрузка со стилем DVD-логотипа** — plymouth-тема: слово `SAFEGAMINGOS` отскакивает от краёв экрана и меняет цвет (как DVD-логотип).
- **Live-окружение**: после загрузки автоматически открывается рабочий стол KDE Plasma 6 (пользователь `live` / пароль `live`, без пароля sudo). В live есть Firefox, PrismLauncher (Minecraft), OBS Studio, драйверы Intel/AMD, звук PipeWire.
- **Инсталлятор на диск**: `sudo sg-install` (или иконка на рабочем столе) — выбор диска, пользователь, пароль; ставит систему через archinstall и брендирует её: та же загрузочная анимация, обои, swapfile 16 ГБ, SafeGuard, multilib + Wine/Steam/Lutris для Windows-игр. **После установки всё готово из коробки**: комнаты (браузер/игры/стрим) уже созданы, на рабочем столе иконки запуска комнат и SafeGuard, ClamAV сам обновляет базы, лимиты CPU/RAM активны.
- **Комнаты изоляции (SafeGuard CLI + GUI)**:
  - `sg-room-run NAME -- приложение` — запуск приложения в изолированной комнате (firejail: отдельные namespace, приватный home, `--noroot`, `--caps.drop=all`, `--seccomp`) **с жёсткими лимитами CPU/RAM** (`--mem 4G --cpu 200`; применяются через cgroup v2/systemd — без swap, с OOM-kill; игровые комнаты по умолчанию 8G/400%).
  - Комната не видит другие комнаты (blacklist чужих home/карантина, home 0700, база 0600 root), лишена sudo/pkexec/su, сессионной и системной D-Bus шины (не-игровые), `/var/tmp`, SysV IPC; `--x11-isolate` даёт отдельный виртуальный дисплей (Xephyr) для X11-сессий.
  - `sg-gui` — графический центр безопасности (PyQt6): комнаты, запуск приложений, игровой режим, карантин, антивирус, блокировки, журнал. Привилегии через pkexec (группа wheel — без пароля).
  - `sg-game-mode ROOM on|off` — игровой режим комнаты: разрешение на доступ к экрану, звуку и вводу сессии (для OBS/стримов/игр); обычные комнаты таких прав не имеют.
  - `sg-av scan ФАЙЛ` — сканирование ClamAV; при обнаружении вируса блокирует источник-URL и предлагает на выбор: карантин комнаты / удалить комнату / оставить.
  - `sg-av live` — живой мониторинг: сколько RAM/CPU реально ест каждая комната (по cgroup).
  - `sg-track ФАЙЛ --url URL` (+ `--watch КАТАЛОГ`) — запоминает, с какого сайта скачан файл.
  - `sg-block-url` / `sg-unblock-url` — блокировка источника в `/etc/hosts` (разблокировка — решение пользователя).
  - `sg-quarantine` / `sg-rooms` / `sg-setup` — карантин и восстановление комнат, список комнат, первичная настройка SafeGuard.
  - Всё логируется в SQLite-базу `/var/lib/sg-rooms/sg.db` и `/var/log/sg-rooms/events.log`.

## Сборка ISO (на Arch Linux)

```bash
sudo pacman -S archiso
sudo ./build_iso.sh          # → out/safegamingos-0.9.0-x86_64.iso
```

Запись на флешку:

```bash
sudo dd bs=4M if=out/safegamingos-0.9.0-x86_64.iso of=/dev/sdX status=progress oflag=sync
```

## Тест (сначала в виртуалке)

1. Создайте VM с UEFI (или используйте QEMU): загрузите ISO.

   ```bash
   # QEMU (пакеты qemu-desktop edk2-ovmf)
   qemu-system-x86_64 -enable-kvm -m 4096 -cpu host -smp 4 \
     -drive file=test.qcow2,if=virtio,format=qcow2 \
     -cdrom out/safegamingos-0.9.0-x86_64.iso -boot d
   ```

2. Дождитесь рабочего стола (автовход `live`).
3. Установка на диск: `sudo sg-install` — выберите виртуальный диск, задайте пользователя и пароль.
4. Перезагрузка — загрузка уже с установленной ОС (та же анимация, рабочий стол, swapfile 16 ГБ, SafeGuard).

Быстрый тест SafeGuard в live/установленной системе:

```bash
sudo sg-rooms                                   # комнаты browser/games/streaming уже созданы
sudo sg-room-run browser -- firefox             # браузер в комнате (или иконка «Браузер» на столе)
sudo sg-track ~/Downloads/setup.exe --url https://example.com/virus.exe
sudo sg-av scan ~/Downloads/setup.exe           # если ClamAV найдёт вирус — предложит блокировку и карантин
sudo sg-rooms                                   # список комнат и разрешений
```

## Red team / blue team

Протокол тестирования изоляции враждебными образцами — `docs/red-team.md`
(цель и правила для красной команды; список уязвимостей ей не выдаётся).
Внутренняя карта угроз — `docs/threat-model.md` (не показывать красной команде).
Гайд сборки для чайников — `docs/build-guide.md`.

## Структура

```
archiso/
  profiledef.sh                 # конфиг mkarchiso (ISO, bootmodes, права файлов)
  packages.x86_64               # пакеты live-ISO (KDE, игры, OBS, SafeGuard, plymouth)
  pacman.conf                   # pacman для сборки (multilib закомментирован)
  syslinux/                     # BIOS-загрузчик (quiet splash)
  efiboot/                      # systemd-boot (UEFI, quiet splash)
  airootfs/
    etc/mkinitcpio.conf.d/      # хук plymouth в initramfs ISO
    etc/mkinitcpio.d/           # пресет сборки initramfs
    etc/sddm.conf.d/            # автовход live-пользователя
    etc/skel/                   # обои + ярлык установки для новых пользователей
    root/customize_airootfs.sh  # настройка live-окружения при сборке
    usr/share/plymouth/themes/safegamingos/   # DVD-анимация загрузки
    usr/share/wallpapers/                      # обои safegamingOS
    usr/local/bin/sg-*          # инсталлятор + инструменты комнат/SafeGuard
    usr/local/lib/sg-rooms/     # lib.sh — ядро комнат (SQLite, карантин, блокировки)
scripts/gen-assets.mjs          # генератор PNG-ассетов (bun run gen:assets)
build_iso.sh                    # сборка ISO (mkarchiso)
```

## Что дальше

- **Авто-трекинг загрузок браузера** — интеграция с Firefox (расширение/скрипт), чтобы источник URL записывался автоматически.
- **Ужесточение изоляции**: AppArmor-профили для комнат, per-room UID (полная файловая изоляция), пер-комнатный файрвол (сеть по умолчанию выключена), per-room звук.
- **Wine/Proton-комнаты**: выбор «Wine или Proton» в инсталляторе, отдельная комната для Windows-игр.
- **Автообновление баз ClamAV** и сканирование по расписанию.

## Честные ограничения v0.9

- Изоляция комнат — на уровне firejail (namespace, seccomp, private home) + будущий AppArmor. Это НЕ гипервизор: ядро общее, поэтому «физически не выберется» — заявленная цель на следующих этапах (AppArmor + cgroups + минимизация прав).
- `sg-install` использует archinstall; если автоконфигурация не совпала с версией archinstall — откроется обычный интерактивный установщик.
- Для антивируса нужен ClamAV: `sudo pacman -S clamav && sudo freshclam`.
