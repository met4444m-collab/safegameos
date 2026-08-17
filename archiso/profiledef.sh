#!/usr/bin/env bash
# safegamingOS archiso profile definition.
# See https://github.com/archlinux/archiso/blob/master/docs/README.profile.rst
# shellcheck disable=SC2034
iso_name="safegamingos"
iso_label="SAFEGAMINGOS"
iso_publisher="safegamingOS Project <https://github.com/met4444m-collab/safegameos>"
iso_application="safegamingOS Live/Install Medium"
iso_version="0.11.2"
install_dir="safegamingos"
buildmodes=('iso')
bootmodes=('bios.syslinux' 'uefi.systemd-boot')
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'xz' '-Xbcj' 'x86' '-b' '1M' '-Xdict-size' '1M')
bootstrap_tarball_compression=('zstd' '-c' '-T0' '--auto-threads=logical' '--long' '-19')
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/root"]="0:0:750"
  ["/root/customize_airootfs.sh"]="0:0:755"
  ["/usr/local/bin/sg-install"]="0:0:755"
  ["/usr/local/bin/sg-install-gui"]="0:0:755"
  ["/usr/local/bin/sg-install-run"]="0:0:755"
  ["/usr/local/bin/sg-reboot"]="0:0:755"
  ["/usr/local/bin/sg-live-installer"]="0:0:755"
  ["/usr/local/bin/sg-live-theme"]="0:0:755"
  ["/usr/local/bin/sg-setup"]="0:0:755"
  ["/usr/local/bin/sg-rooms"]="0:0:755"
  ["/usr/local/bin/sg-room-run"]="0:0:755"
  ["/usr/local/bin/sg-game-mode"]="0:0:755"
  ["/usr/local/bin/sg-net"]="0:0:755"
  ["/usr/local/bin/sg-av"]="0:0:755"
  ["/usr/local/bin/sg-block-url"]="0:0:755"
  ["/usr/local/bin/sg-unblock-url"]="0:0:755"
  ["/usr/local/bin/sg-track"]="0:0:755"
  ["/usr/local/bin/sg-track-daemon"]="0:0:755"
  ["/usr/local/bin/sg-db-view"]="0:0:755"
  ["/usr/local/bin/sg-quarantine"]="0:0:755"
  ["/usr/local/bin/sg-gui"]="0:0:755"
  ["/usr/local/bin/sg-open"]="0:0:755"
  ["/usr/local/lib/sg-rooms"]="0:0:755"
)
