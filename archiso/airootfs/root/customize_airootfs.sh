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

echo ":: safegamingOS customize_airootfs: live user"

# --- live desktop user (password 'live', full sudo without prompt) ---
# Groups: wheel + desktop/media groups so the live session has sound (pipewire),
# GPU/DRM access, input devices, power control and removable media.
useradd -m -G wheel,audio,video,input,storage,power,users,network,optical,rfkill -s /bin/bash live
echo 'live:live' | chpasswd
echo 'live ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/10-live
chmod 440 /etc/sudoers.d/10-live

echo ":: safegamingOS customize_airootfs: services"

# --- services ---
systemctl enable NetworkManager sddm >/dev/null 2>&1 || true
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

echo ":: safegamingOS customize_airootfs: done"
exit 0
