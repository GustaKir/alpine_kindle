#!/usr/bin/env bash
REPO="http://dl-cdn.alpinelinux.org/alpine"
REV="v3.19"
MNT="/mnt/alpine"
IMAGE="./alpine.ext3"
IMAGESIZE=3096 #Megabytes
ALPINESETUP="source /etc/profile
echo kindle > /etc/hostname
echo \"nameserver 8.8.8.8\" > /etc/resolv.conf
mkdir /run/dbus
apk update
apk upgrade
cat /etc/alpine-release

# Install core packages first
apk add --no-cache xorg-server-xephyr xwininfo xdotool xinput dbus-x11 sudo bash nano git seatd

# Install desktop environment basics
apk add --no-cache desktop-file-utils gtk-engines consolekit gtk-murrine-engine caja caja-extensions marco

# Install fonts (skip problematic ones)
apk add --no-cache font-dejavu font-liberation ttf-liberation font-opensans

# Try to install phosh components (skip if they fail)
apk add --no-cache phosh-wallpapers || echo 'Warning: phosh-wallpapers failed to install'
apk add --no-cache phoc || echo 'Warning: phoc failed to install'
apk add --no-cache phosh-mobile-settings || echo 'Warning: phosh-mobile-settings failed to install'

# Install virtual keyboard (prefer squeekboard over stevia to avoid conflicts)
apk add --no-cache squeekboard || apk add --no-cache onboard || echo 'Warning: No virtual keyboard could be installed'

# Install browser
apk add --no-cache chromium || echo 'Warning: Chromium failed to install'

# User setup
adduser alpine -D
echo -e \"alpine\nalpine\" | passwd alpine
echo '%sudo ALL=(ALL) ALL' >> /etc/sudoers
addgroup sudo
addgroup alpine sudo

# Try to setup dotfiles (skip if git operations fail)
su alpine -c \"cd ~
git init
git remote add origin https://github.com/schuhumi/alpine_kindle_dotfiles
git pull origin master || echo 'Warning: Git pull failed'
git reset --hard origin/master || echo 'Warning: Git reset failed'
dconf load /org/mate/ < ~/.config/org_mate.dconf.dump 2>/dev/null || echo 'Warning: dconf load failed'
dconf load /org/onboard/ < ~/.config/org_onboard.dconf.dump 2>/dev/null || echo 'Warning: dconf load failed'\" || echo 'Warning: User setup failed'

# Create chromium config directory and file
mkdir -p /etc/chromium
echo '# Default settings for chromium. This file is sourced by /bin/sh from
# the chromium launcher.

# Options to pass to chromium.
mouseid=\"\$(env DISPLAY=:1 xinput list --id-only \"Xephyr virtual mouse\" 2>/dev/null || echo 1)\"
CHROMIUM_FLAGS='\''--force-device-scale-factor=2 --touch-devices='\''\$mouseid'\'' --pull-to-refresh=1 --disable-smooth-scrolling --enable-low-end-device-mode --disable-login-animations --disable-modal-animations --wm-window-animations-disabled --start-maximized --user-agent=Mozilla%2F5.0%20%28Linux%3B%20Android%207.0%3B%20SM-G930V%20Build%2FNRD90M%29%20AppleWebKit%2F537.36%20%28KHTML%2C%20like%20Gecko%29%20Chrome%2F59.0.3071.125%20Mobile%20Safari%2F537.36'\''' > /etc/chromium/chromium.conf
mkdir -p /usr/share/chromium/extensions

echo \"You're now dropped into an interactive shell in Alpine, feel free to explore and type exit to leave.\"
sh"

STARTGUI='#!/bin/sh
chmod a+w /dev/shm # Otherwise the alpine user cannot use this (needed for chromium)
SIZE=$(xwininfo -root -display :0 2>/dev/null | egrep "geometry" | cut -d " "  -f4 || echo "800x600")
env DISPLAY=:0 Xephyr :1 -title "L:D_N:application_ID:xephyr" -ac -br -screen $SIZE -cc 4 -reset -terminate & 
sleep 3 
# Try phosh-session first, fallback to simple window manager
if command -v phosh-session >/dev/null 2>&1; then
    su alpine -c "env DISPLAY=:1 phosh-session"
elif command -v marco >/dev/null 2>&1; then
    su alpine -c "env DISPLAY=:1 marco &"
    su alpine -c "env DISPLAY=:1 caja &"
else
    su alpine -c "env DISPLAY=:1 xterm"
fi
killall Xephyr'

# ENSURE ROOT
# This script needs root access to e.g. mount the image
[ "$(whoami)" != "root" ] && echo "This script needs to be run as root" && exec sudo -- "$0" "$@"

# Install required packages on host
echo "Installing required packages..."
apt-get update
apt-get install -y zip gzip qemu-user-static binfmt-support

# GETTING APK-TOOLS-STATIC
echo "Determining version of apk-tools-static"
curl -f "$REPO/$REV/main/armhf/APKINDEX.tar.gz" --output /tmp/APKINDEX.tar.gz || {
    echo "Error: Failed to download APKINDEX"
    exit 1
}

tar -xzf /tmp/APKINDEX.tar.gz -C /tmp
APKVER="$(cut -d':' -f2 <<<"$(grep -A 5 "P:apk-tools-static" /tmp/APKINDEX | grep "V:")")"
rm /tmp/APKINDEX /tmp/APKINDEX.tar.gz /tmp/DESCRIPTION 2>/dev/null || true
echo "Version of apk-tools-static is: $APKVER"

echo "Downloading apk-tools-static"
curl -f "$REPO/$REV/main/armv7/apk-tools-static-$APKVER.apk" --output "/tmp/apk-tools-static.apk" || {
    echo "Error: Failed to download apk-tools-static"
    exit 1
}
tar -xzf "/tmp/apk-tools-static.apk" -C /tmp

# CREATING IMAGE FILE
echo "Creating image file"
dd if=/dev/zero of="$IMAGE" bs=1M count=$IMAGESIZE status=progress
mkfs.ext3 "$IMAGE"
tune2fs -i 0 -c 0 "$IMAGE"

# MOUNTING IMAGE
echo "Mounting image"
mkdir -p "$MNT"
mount -o loop -t ext3 "$IMAGE" "$MNT"

# BOOTSTRAPPING ALPINE
echo "Bootstrapping Alpine"
qemu-arm-static /tmp/sbin/apk.static -X "$REPO/$REV/main" -U --allow-untrusted --root "$MNT" --initdb add alpine-base

# COMPLETE IMAGE MOUNTING FOR CHROOT
mount /dev/ "$MNT/dev/" --bind
mount -t proc none "$MNT/proc"
mount -o bind /sys "$MNT/sys"

# CONFIGURE ALPINE
cp /etc/resolv.conf "$MNT/etc/resolv.conf" 2>/dev/null || echo "nameserver 8.8.8.8" > "$MNT/etc/resolv.conf"

mkdir -p "$MNT/etc/apk"
echo "$REPO/$REV/main/
$REPO/$REV/community/
$REPO/latest-stable/community" > "$MNT/etc/apk/repositories"

# Create the script to start the gui
echo "$STARTGUI" > "$MNT/startgui.sh"
chmod +x "$MNT/startgui.sh"

# CHROOT
cp $(which qemu-arm-static) "$MNT/usr/bin/"
echo "Chrooting into Alpine"
chroot "$MNT" qemu-arm-static /bin/sh -c "$ALPINESETUP"
rm "$MNT/usr/bin/qemu-arm-static"

# UNMOUNT IMAGE & CLEANUP
sync
# Kill remaining processes more safely
lsof +f -t "$MNT" 2>/dev/null | xargs -r kill -9 2>/dev/null || true

echo "Unmounting image"
umount "$MNT/sys" 2>/dev/null || true
umount "$MNT/proc" 2>/dev/null || true
umount -lf "$MNT/dev" 2>/dev/null || true
umount "$MNT" 2>/dev/null || true

# Wait for unmount to complete
for i in {1..30}; do
    if ! mount | grep -q "$MNT"; then
        break
    fi
    echo "Waiting for unmount to complete... ($i/30)"
    sleep 2
    umount "$MNT" 2>/dev/null || true
done

if mount | grep -q "$MNT"; then
    echo "Warning: Could not unmount $MNT completely"
else
    echo "Alpine unmounted successfully"
fi

# Cleanup
echo "Cleaning up"
rm -f /tmp/apk-tools-static.apk
rm -rf /tmp/sbin

echo "Image creation completed!"
