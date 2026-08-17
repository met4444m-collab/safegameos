#!/usr/bin/env bash
# safegamingOS — customize the live airootfs (runs at ISO build time, chrooted).
set -euo pipefail

echo ":: safegamingOS customize_airootfs: locale/keyboard"

# --- locale, keyboard, hostname ---
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen >/dev/null 2>&1
echo 'LANG=en_US.UTF-8' > /etc/locale.conf
echo 'KEYMAP=us' > /etc/vconsole.conf
echo 'safegamingos-live' > /etc/hostname
ln -sf /usr/share/zoneinfo/UTC /etc/localtime

# --- branding: os-release (live medium). /etc/os-release is a symlink to
#     /usr/lib/os-release on Arch — write the real file there. ---
cat > /usr/lib/os-release <<'EOF'
NAME="safegamingOS"
PRETTY_NAME="safegamingOS 0.11.1"
ID=safegamingos
ID_LIKE=arch
BUILD_ID=rolling
ANSI_COLOR="38;2;45;212;167"
HOME_URL="https://github.com/met4444m-collab/safegameos"
LOGO=safegamingos
EOF
# версия для автообновления (sg-update сверяет с релизами GitHub)
mkdir -p /usr/share/safegamingos
printf '%s\n' '0.11.1' > /usr/share/safegamingos/version

echo ":: safegamingOS customize_airootfs: live user"

# --- live desktop user (full sudo without prompt, NO password at all) ---
# Groups: wheel + desktop/media groups so the live session has sound (pipewire),
# GPU/DRM access, input devices, power control and removable media.
useradd -m -G wheel,audio,video,input,storage,power,users,network,optical,rfkill -s /bin/bash live
# Автовход SDDM на Arch срабатывает ТОЛЬКО если пользователь состоит в группе
# autologin (иначе автовход молча не происходит и показывается экран логина —
# именно поэтому пользователь видел запрос пароля). Группа nopasswdlogin —
# страховка: если автовход по любой причине не сработал, ручной вход проходит
# с пустым паролем.
groupadd -r autologin 2>/dev/null || true
groupadd -r nopasswdlogin 2>/dev/null || true
usermod -aG autologin,nopasswdlogin live
# Вход в ОС вообще без пароля: автовход в рабочий стол + пустой пароль на TTY.
passwd -d live
echo 'live ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/10-live
chmod 440 /etc/sudoers.d/10-live

# --- branding: make sure the skel theme/installer autostart lands in the
#     live user's home, and new scripts are executable ---
chmod +x /usr/local/bin/sg-live-installer /usr/local/bin/sg-live-theme 2>/dev/null || true
# KDE trusts desktop icons only when they are executable (no "Allow launching" prompt)
chmod +x /etc/skel/Desktop/*.desktop 2>/dev/null || true
mkdir -p /home/live/.config/autostart
cp -f /etc/skel/.config/autostart/sg-wallpaper.desktop /home/live/.config/autostart/ 2>/dev/null || true
cp -f /etc/skel/.config/autostart/sg-installer.desktop /home/live/.config/autostart/ 2>/dev/null || true
cp -f /etc/skel/.config/autostart/sg-update.desktop /home/live/.config/autostart/ 2>/dev/null || true
mkdir -p /home/live/.config/systemd/user
cp -f /etc/skel/.config/systemd/user/sg-update-check.service \
      /etc/skel/.config/systemd/user/sg-update-check.timer \
      /home/live/.config/systemd/user/ 2>/dev/null || true
cp -f /etc/skel/Desktop/*.desktop /home/live/Desktop/ 2>/dev/null || true
chmod +x /home/live/Desktop/*.desktop 2>/dev/null || true
chown -R live:live /home/live/.config /home/live/Desktop 2>/dev/null || true

echo ":: safegamingOS customize_airootfs: services"

# --- services ---
systemctl enable NetworkManager sddm sg-watch sg-track nftables >/dev/null 2>&1 || true
systemctl set-default graphical.target >/dev/null 2>&1 || true

echo ":: safegamingOS customize_airootfs: plymouth theme"

# --- boot splash: set our theme and rebuild the initramfs so the theme
#     (and the plymouth hook) end up inside the live ISO initramfs ---
if command -v plymouth-set-default-theme >/dev/null 2>&1; then
  plymouth-set-default-theme safegamingos || true
  mkinitcpio -P >/dev/null 2>&1 || true
fi

echo ":: safegamingOS customize_airootfs: SafeGuard room DB"

# --- initialize the room-isolation database used by SafeGuard tooling ---
if [[ -f /usr/local/lib/sg-rooms/lib.sh ]]; then
  # shellcheck source=/dev/null
  source /usr/local/lib/sg-rooms/lib.sh
  sg_ensure_db || true
  sg_default_rooms || true
fi

# --- AppArmor: enforcement layer for rooms (live session) ---
if systemctl list-unit-files apparmor.service >/dev/null 2>&1; then
  systemctl enable apparmor >/dev/null 2>&1 || true
  systemctl start apparmor >/dev/null 2>&1 || true
fi

echo ":: safegamingOS customize_airootfs: offline install bundle"

# --- Офлайн-набор для установки без интернета скачивается НА ХОСТЕ
#     (build_iso.sh) в archiso/airootfs/opt/sg-offline и попадает сюда через
#     overlay airootfs. В chroot pacman без сети (pacstrap качает на хосте),
#     поэтому здесь — только проверка: набора нет → ISO бесполезен для
#     офлайн-установки (главная фича), сборку прерываем громко. ---
if [[ -f /opt/sg-offline/READY && -d /opt/sg-offline/pkgs ]]; then
  echo ":: офлайн-набор: $(ls /opt/sg-offline/pkgs/*.pkg.tar.* 2>/dev/null | wc -l) пакетов, $(du -sh /opt/sg-offline/pkgs 2>/dev/null | cut -f1)"
else
  echo ":: ОШИБКА: офлайн-набор /opt/sg-offline не найден (нет READY/pkgs)." >&2
  echo ":: Он создаётся на хосте в build_iso.sh (build_offline_bundle)." >&2
  echo ":: Сборка прервана — не выпускаем ISO без офлайн-установки." >&2
  exit 1
fi
# кеш pacstrap в live-системе не нужен (дублирует офлайн-набор) — убираем,
# чтобы не раздувать squashfs и не тратить диски раннера
rm -rf /var/cache/pacman/pkg/* 2>/dev/null || true

echo ":: safegamingOS customize_airootfs: done"
exit 0
