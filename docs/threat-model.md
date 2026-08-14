# Внутренняя модель угроз safegamingOS

> ⚠️ **НЕ для красной команды.** Это внутренняя карта слабых мест. Красная
> команда получает `docs/red-team.md` (цель и правила, без списка векторов).

Обновлено после раунда усиления «harden-2» (см. git-историю).

## Статус векторов

| # | Вектор | Статус |
|---|--------|--------|
| 1 | **X11**: чтение экрана/клавиатуры чужих приложений | ✅ закрыто по умолчанию: сессия KDE Plasma 6 — **Wayland**, X11-инструменты (`xwd`, `xinput`, `xwininfo`) не видят нативные окна и реальный ввод. На X11-сессии — `sg-room-run --x11-isolate` (Xephyr: отдельный виртуальный дисплей). Игровые комнаты сознательно имеют доступ к реальному дисплею (OBS/стрим) |
| 2 | **D-Bus сессионная шина** (управление KDE/приложениями сессии) | ✅ не-игровые комнаты: `--dbus-user=none` |
| 2b | **D-Bus системная шина** (org.freedesktop.*, NetworkManager...) | ✅ не-игровые комнаты: `--dbus-system=none` (есть guard по версии firejail) |
| 3 | **DoS CPU/RAM** (майнер, fork-бомба) | ✅ cgroup v2 через systemd-скоуп: MemoryMax, MemorySwapMax=0, CPUQuota, TasksMax=256, OOMPolicy=kill |
| 4 | **Межкомнатный файловый доступ** (same-UID: комната A читает home комнаты B, карантин, базу) | ✅ blacklist чужих home и карантина в каждой комнате; home 0700; `sg.db` 0600 root; каталоги 0700 root |
| 5 | **setuid-лестница**: sudo/pkexec/su/runuser внутри комнаты → root → побег | ✅ blacklist `/usr/bin/sudo`, `/usr/bin/pkexec`, `/usr/bin/su`, `/usr/bin/runuser` |
| 6 | **/tmp** общий | ✅ `--private-tmp` |
| 6b | **/var/tmp** общий (межкомнатный почтовый ящик, персистентность) | ✅ blacklist `/var/tmp` |
| 7 | **SysV IPC** между комнатами | ✅ `--ipc-namespace` |
| 8 | **machine-id** (трекинг, связывание с хостом) | ✅ `--machine-id` (случайный в песочнице) |
| 9 | **Сеть наружу** (экфильтрация, C2) | ⚠️ открыта по умолчанию — браузер/игры/стрим нуждаются в сети; `--offline` = `--net=none`. План: пер-комнатный nftables + allowlist |
| 10 | **Аудио-захват** (PipeWire/Pulse сокет в `/run/user/1000`) | ⚠️ не-игровые комнаты могут слушать звук сессии (нужен браузеру). План: per-room sound routing |
| 11 | **/dev/shm** | ⚠️ общий (нужен приложениям). План: per-room tmpfs → требует per-room UID |
| 12 | **/proc**: чужие процессы и environ (same-UID) | ⚠️ открыто. План: per-room UID + hidepid |
| 13 | **AppArmor-профили** комнат (MAC поверх firejail) | ❌ не настроены. План: профили на запускаемые бинарники + deny на хост-пути |
| 14 | **Ядро**: 0-day / известные CVE (firejail suid, kernel) | ❌ общее ядро — принципиальный предел firejail-подхода; снижается свежим ядром + AppArmor |
| 15 | **Пути firejail наружу**: профили в `/etc/firejail`, `--join` с хоста, конфиги | ⚠️ проверить в VM: владелец `/etc/firejail`, возможность `--join` со стороны хост-юзера |
| 16 | **KLauncher (`org.kde.klauncher5`)** — из комнаты с session bus можно дёрнуть `start_service_by_desktop_name` / `exec_blind` → запуск произвольной программы от имени хост-юзера **вне** песочницы | ⚠️ не-игровые комнаты: закрыто (`--dbus-user=none`). Игровые: session bus открыт (нужен OBS/портал) — klauncher достижим. План: per-room UID/сессия, либо `--dbus-user=filter` (нужен прогон в VM, чтобы не сломать OBS) |

## Принципиальный предел (честно)

Комнаты работают от имени **одного системного пользователя**. Всё, что Linux
разрешает процессам одного UID (чтение чужих 0600-файлов, `/proc`, сокеты
`/run/user`), firejail закрывает только чёрными списками — это defence-in-depth,
а не гарантия. Полная файловая/процессная изоляция требует **per-room UID**
(отдельный пользователь на комнату + home 0700 + своя сессия) — следующий
этап. AppArmor добавит MAC-слой поверх. До этого момента «физически не
выберется» — маркетинг, а не факт.

## Чек-лист перепроверки (после harden-2, в VM)

```bash
sudo sg-room-run redteam -- bash    # внутри комнаты:
# ls /var/lib/sg-rooms              → закрыто (blacklist)
# cat /var/lib/sg-rooms/sg.db       → нет доступа
# sudo / pkexec / su                → нет файла (blacklist)
# dbus-send --system ... ListNames  → ошибка
# dd if=/dev/zero of=/var/tmp/x     → нет доступа
# ipcs                              → отдельный namespace (пусто)
# stress --cpu 4                    → упор в CPUQuota, хост жив

# две комнаты одновременно:
sudo sg-room-run browser -- firefox
sudo sg-room-run games -- prismlauncher   # в games: ls /var/lib/sg-rooms → закрыто
```
