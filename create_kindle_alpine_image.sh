#!/usr/bin/env bash
set -euo pipefail

REPO="http://dl-cdn.alpinelinux.org/alpine"
REV="v3.19"
MNT="/mnt/alpine"
IMAGE="./alpine.ext3"
IMAGESIZE=3096 # MB

ALPINESETUP="set -e
source /etc/profile
export LANG=C.UTF-8 LC_ALL=C.UTF-8
echo kindle > /etc/hostname
echo 'nameserver 8.8.8.8' > /etc/resolv.conf
mkdir -p /run/dbus
apk update
apk upgrade
cat /etc/alpine-release

# Install core packages
apk add --no-cache xorg-server-xephyr xwininfo xdotool xinput dbus-x11 sudo bash nano git seatd

# Desktop environment basics
apk add --no-cache desktop-file-utils gtk-engines consolekit gtk-murrine-engine caja caja-extensions marco

# Fonts
apk add --no-cache font-dejavu font-liberation ttf-liberation font-opensans

# Phosh components (optional)
apk add --no-cache phosh-wallpapers || echo 'Warning: phosh-wallpapers failed'
apk add --no-cache phoc || echo 'Warning: phoc failed'
apk add --no-cache phosh-mobile-settings || echo 'Warning: phosh-mobile-settings failed'

# Virtual keyboard
apk add --no-cache squeekboard || apk add --no-cache onboard || echo 'Warning: No virtual keyboard could be installed'

# Browser (optional, often fails on ARM)
apk add --no-cache chromium || echo 'Warning: Chromium failed to install'

# User setup
adduser alpine -D
echo -e 'alpine\nalpine' | passwd alpine
echo '%sudo ALL=(ALL) ALL' >> /etc/sudoers
addgroup sudo
addgroup alpine sudo

# Dotfiles (optional)
su alpine -c \"cd ~
git init
git remote add origin https://github.com/schuhumi/alpine_kindle_dotfiles
git pull origin master || echo 'Warning: Git pull failed'
git reset --hard origin/master || echo 'Warning: Git reset failed'
dconf load /org/mate/ < ~/.config/org_mate.dconf.dump 2>/dev/null || echo 'Warning: dconf load failed'
dconf load /org/onboard/ < ~/.config/org_onboard.dconf.dump 2>/dev/null || echo 'Warning: dconf load failed'\" || echo 'Warning: User setup failed'

# Chromium config
mkdir -p /etc/chromium
cat <<EOF > /etc/chromium/default
# Default settings for chromium.
mouseid=\"\$(env DISPLAY=:1 xinput list --id-only \"Xephyr virtual mouse\" 2>/dev/null || echo 1)\"
CHROMIUM_FLAGS='--force-device-scale-factor=2 --touch-devices='\$mouseid' --pull-to-refresh=1 --disable-smooth-scrolling --enable-low-end-device-mode --disable-login-animations --disable-moda[...]
EOF
mkdir -p /usr/share/chromium/extensions

echo \"You're now dropped into an interactive shell in Alpine, feel free to explore and type exit to leave.\"
sh
"

STARTGUI="#!/bin/sh
chmod a+w /dev/shm
SIZE=\$(xwininfo -root -display :0 2>/dev/null | grep geometry | cut -d ' ' -f4 || echo '800x600')
env DISPLAY=:0 Xephyr :1 -title 'L:D_N:application_ID:xephyr' -ac -br -screen \$SIZE -cc 4 -reset -terminate &
sleep 3
if command -v phosh-session >/dev/null 2>&1; then
    su alpine -c 'env DISPLAY=:1 phosh-session'
elif command -v marco >/dev/null 2>&1; then
    su alpine -c 'env DISPLAY=:1 marco &' 
    su alpine -c 'env DISPLAY=:1 caja &'
else
    su alpine -c 'env DISPLAY=:1 xterm'
fi
killall Xephyr
"

# ENSURE ROOT
if [ \"\$(id -u)\" -ne 0 ]; then
  echo \"This script needs to be run as root\"
  exec sudo -- \"\$0\" \"\$@\"
fi

echo \"Installing required packages...\"
apt-get update
apt-get install -y zip gzip qemu-user-static binfmt-support

# GET APK-TOOLS-STATIC
echo \"Determining version of apk-tools-static\"
curl -f \"$REPO/$REV/main/armhf/APKINDEX.tar.gz\" --output /tmp/APKINDEX.tar.gz
tar -xzf /tmp/APKINDEX.tar.gz -C /tmp
APKVER=\$(awk -F: '/P:apk-tools-static/{getline; if(\$1==\"V\") print \$2}' /tmp/APKINDEX)
echo \"Version of apk-tools-static is: \$APKVER\"
curl -f \"$REPO/$REV/main/armv7/apk-tools-static-\$APKVER.apk\" --output /tmp/apk-tools-static.apk
tar -xzf /tmp/apk-tools-static.apk -C /tmp

# CREATE IMAGE
echo \"Creating image file\"
dd if=/dev/zero of=\"$IMAGE\" bs=1M count=$IMAGESIZE status=progress
mkfs.ext3 \"$IMAGE\"
tune2fs -i 0 -c 0 \"$IMAGE\"

echo \"Mounting image\"
mkdir -p \"$MNT\"
mount -o loop -t ext3 \"$IMAGE\" \"$MNT\"

echo \"Bootstrapping Alpine\"
qemu-arm-static /tmp/sbin/apk.static -X \"$REPO/$REV/main\" -U --allow-untrusted --root \"$MNT\" --initdb add alpine-base

mount --bind /dev \"$MNT/dev\"
mount -t proc none \"$MNT/proc\"
mount --bind /sys \"$MNT/sys\"

cp /etc/resolv.conf \"$MNT/etc/resolv.conf\" || echo 'nameserver 8.8.8.8' > \"$MNT/etc/resolv.conf\"

# ONLY use v3.19 repos
cat <<EOF > \"$MNT/etc/apk/repositories\"
$REPO/$REV/main
$REPO/$REV/community
EOF

# GUI launcher
echo \"$STARTGUI\" > \"$MNT/startgui.sh\"
chmod +x \"$MNT/startgui.sh\"

cp \$(which qemu-arm-static) \"$MNT/usr/bin/\"
echo \"Chrooting into Alpine\"
chroot \"$MNT\" qemu-arm-static /bin/sh -c \"$ALPINESETUP\"
rm \"$MNT/usr/bin/qemu-arm-static\"

sync
lsof +f -t \"$MNT\" 2>/dev/null | xargs -r kill -9 2>/dev/null || true

echo \"Unmounting image\"
umount \"$MNT/sys\" 2>/dev/null || true
umount \"$MNT/proc\" 2>/dev/null || true
umount -lf \"$MNT/dev\" 2>/dev/null || true
umount \"$MNT\" 2>/dev/null || true

for i in {1..30}; do
    if ! mount | grep -q \"$MNT\"; then
        break
    fi
    echo \"Waiting for unmount to complete... (\$i/30)\"
    sleep 2
    umount \"$MNT\" 2>/dev/null || true
done

if mount | grep -q \"$MNT\"; then
    echo \"Warning: Could not unmount $MNT completely\"
else
    echo \"Alpine unmounted successfully\"
fi

echo \"Cleaning up\"
rm -f /tmp/apk-tools-static.apk
rm -rf /tmp/sbin

echo \"Image creation completed!\"
