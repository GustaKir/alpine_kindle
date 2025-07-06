#!/usr/bin/env bash

# DEPENDENCIES
# qemu-user-static is required to run arm software using the "qemu-arm-static" command (I suppose you use this script on a X86_64 computer)
# Please install it via your package manager (e.g. Ubuntu) or whatever way is appropriate for your distribution (Arch has it in AUR)

# BASIC CONIGURATION
# REPO: The Alpine repository to use, you can leave it like it is
# MNT: Where you want to mount the image, just make sure /mnt/alpine isn't already used
# IMAGE: The path and name of the image file to be created, you can leave it as is
# IMAGESIZE: How big you want the image to be. If you want to install Chromium, a evince etc. you should go for at least 1400MB
# ALPINESETUP: This are the commands executed inside the Alpine container to set it up. Most notably it installs XFCE desktop environment,
# and creates a user named "alpine" with password "alpine". The last command is "sh", which allows you to examine the
# created image/install more packages/whatever. To finish the script just leave the sh shell with "exit"
# STARGUI: This is the script that gets executed inside the container when the GUI is started. Weston is used to render the desktop
# inside a window on the host X display, that has the correct name to be displayed in fullscreen by the kindle's awesome windowmanager

REPO="http://dl-cdn.alpinelinux.org/alpine"
MNT="/mnt/alpine"
IMAGE="./alpine.ext3"
IMAGESIZE=2048 #Megabytes

ALPINESETUP="source /etc/profile
echo kindle > /etc/hostname
echo \"nameserver 8.8.8.8\" > /etc/resolv.conf
mkdir /run/dbus
apk update
apk upgrade
cat /etc/alpine-release

# Removed xorg-server-xephyr, xwininfo, xdotool, xinput
# Added weston, xwayland
apk add weston xwayland dbus-x11 sudo bash nano git seatd xdg-desktop-portal-phosh phosh-wallpapers phosh-mobile-settings phoc phosh-portalsconf phosh-mobile-settings-lang phosh-lang libphosh
apk add desktop-file-utils gtk-engines gtk-murrine-engine caja caja-extensions marco
apk add $(apk search phosh -q | grep -v '\-dev' | grep -v '\-lang' | grep -v '\-doc' | grep -v 'squeekboard') stevia
apk add onboard firefox

adduser alpine -D
echo -e \"alpine\nalpine\" | passwd alpine
echo '%sudo ALL=(ALL) ALL' >> /etc/sudoers
addgroup sudo
addgroup alpine sudo

# Ensure the alpine user has XDG_RUNTIME_DIR set up, as it's crucial for Wayland
# Although seatd usually handles this, doing it explicitly here for robustness in chroot.
su alpine -c \"
    export XDG_RUNTIME_DIR=/run/user/\$(id -u)
    mkdir -p \$XDG_RUNTIME_DIR
    chmod 0700 \$XDG_RUNTIME_DIR
    
    cd ~
    git init
    git remote add origin https://github.com/schuhumi/alpine_kindle_dotfiles
    git pull origin master
    git reset --hard origin/master
    dconf load /org/mate/ < ~/.config/org_mate.dconf.dump
    dconf load /org/onboard/ < ~/.config/org_onboard.dconf.dump
\"

echo \"You're now dropped into an interactive shell in Alpine, feel free to explore and type exit to leave.\"
sh"

# STARTGUI: Modified to use Weston with its X11 backend
STARTGUI='#!/bin/sh
chmod a+w /dev/shm # Otherwise the alpine user cannot use this (needed for chromium)

# Get the size of the host X display
# This is crucial for Weston to create a window of the correct size on the host.
SIZE=$(xwininfo -root -display :0 | egrep "geometry" | cut -d " " -f4)
WIDTH=${SIZE%x*}
HEIGHT=${SIZE#*x}

# Ensure XDG_RUNTIME_DIR is set for the alpine user if it wasn''t handled by login/seatd
ALPINE_UID=$(id -u alpine)
ALPINE_XDG_RUNTIME_DIR="/run/user/${ALPINE_UID}"
mkdir -p "${ALPINE_XDG_RUNTIME_DIR}"
chown alpine:alpine "${ALPINE_XDG_RUNTIME_DIR}"
chmod 0700 "${ALPINE_XDG_RUNTIME_DIR}"

# Launch Weston with the X11 backend
# -Bx11: Specifies the X11 backend
# --xwayland: Enables XWayland for running X11 applications
# --width and --height: Set the window size on the host X display
# --title: Set the window title for the Kindle''s window manager
# --no-cursor: Optional, hides Weston''s cursor if you prefer the host''s or none.
env DISPLAY=:0 su alpine -c "XDG_RUNTIME_DIR=${ALPINE_XDG_RUNTIME_DIR} weston --backend=x11 --xwayland --width ${WIDTH} --height ${HEIGHT} --title \"L:D_N:application_ID:weston\" &"
WESTON_PID=$!
sleep 5 # Give Weston some time to start up and create its Wayland socket

# Find the Wayland socket created by Weston (usually in XDG_RUNTIME_DIR)
# This is then passed to phosh-session.
WAYLAND_SOCKET=$(ls ${ALPINE_XDG_RUNTIME_DIR}/wayland-*)
if [ -z "$WAYLAND_SOCKET" ]; then
    echo "Error: Weston Wayland socket not found. Phosh might not start."
    exit 1
fi

# Launch phosh-session within the Weston environment
# We explicitly set WAYLAND_DISPLAY to the socket found.
su alpine -c "XDG_RUNTIME_DIR=${ALPINE_XDG_RUNTIME_DIR} WAYLAND_DISPLAY=${WAYLAND_SOCKET} phosh-session" &

# Wait for Weston process to exit, then clean up
wait $WESTON_PID
killall weston # Ensure Weston is fully terminated
'

# ENSURE ROOT
# This script needs root access to e.g. mount the image
[ "$(whoami)" != "root" ] && echo "This script needs to be run as root" && exec sudo -- "$0" "$@"

# GETTING APK-TOOLS-STATIC
# This tool is used to bootstrap Alpine Linux. It is hosted in the Alpine repositories like any other package, and we need to
# read in the APKINDEX what version it is currently to get the correct download link. It is extracted in /tmp and deleted
# again at the end of the script
echo "Determining version of apk-tools-static"
curl "$REPO/latest-stable/main/armhf/APKINDEX.tar.gz" --output /tmp/APKINDEX.tar.gz
tar -xzf /tmp/APKINDEX.tar.gz -C /tmp
APKVER="$(cut -d':' -f2 <<<"$(grep -A 5 "P:apk-tools-static" /tmp/APKINDEX | grep "V:")")" # Grep for the version in APKINDEX
rm /tmp/APKINDEX /tmp/APKINDEX.tar.gz /tmp/DESCRIPTION # Remove what we downloaded and extracted
echo "Version of apk-tools-static is: $APKVER"
echo "Downloading apk-tools-static"
curl "$REPO/latest-stable/main/armv7/apk-tools-static-$APKVER.apk" --output "/tmp/apk-tools-static.apk"
tar -xzf "/tmp/apk-tools-static.apk" -C /tmp # extract apk-tools-static to /tmp

# CREATING IMAGE FILE
# To create the image file, a file full of zeros with the desired size is created using dd. An ext3-filesystem is created in it.
# Also automatic checks are disabled using tune2fs
echo "Creating image file"
dd if=/dev/zero of="$IMAGE" bs=1M count=$IMAGESIZE
mkfs.ext3 "$IMAGE"
tune2fs -i 0 -c 0 "$IMAGE"

# MOUNTING IMAGE
# The mountpoint is created (doesn't matter if it exists already) and the empty ext3-filsystem is mounted in it
echo "Mounting image"
mkdir -p "$MNT"
mount -o loop -t ext3 "$IMAGE" "$MNT"

# BOOTSTRAPPING ALPINE
# Here most of the magic happens. The apk tool we extracted earlier is invoked to create the root filesystem of Alpine inside the
# mounted image. We use the arm-version of it to end up with a root filesystem for arm. Also the "edge" repository is used
# to end up with the newest software, some of which is very useful for Kindles
echo "Bootstrapping Alpine"
qemu-arm-static /tmp/sbin/apk.static -X "$REPO/edge/main" -U --allow-untrusted --root "$MNT" --initdb add alpine-base

# COMPLETE IMAGE MOUNTING FOR CHROOT
# Some more things are needed inside the chroot to be able to work in it (for network connection etc.)
mount /dev/ "$MNT/dev/" --bind
mount -t proc none "$MNT/proc"
mount -o bind /sys "$MNT/sys"

# CONFIGURE ALPINE
# Some configuration needed
cp /etc/resolv.conf "$MNT/etc/resolv.conf" # Copy resolv from host for internet connection
# Configure repositories for apk (edge main+community+testing for lots of useful and up-to-date software)
mkdir -p "$MNT/etc/apk"
echo "$REPO/edge/main/
$REPO/edge/community/
$REPO/edge/testing/
#Here comes a hack because Chromium isn't in edge
$REPO/latest-stable/community" > "$MNT/etc/apk/repositories"
# Create the script to start the gui
echo "$STARTGUI" > "$MNT/startgui.sh"
chmod +x "$MNT/startgui.sh"

# CHROOT
# Here we run arm-software inside the Alpine container, and thus we need the qemu-arm-static binary in it
cp $(which qemu-arm-static) "$MNT/usr/bin/"
# Chroot and run the setup as specified at the beginning of the script
echo "Chrooting into Alpine"
chroot /mnt/alpine/ qemu-arm-static /bin/sh -c "$ALPINESETUP"
# Remove the qemu-arm-static binary again, it's not needed on the kindle
rm "$MNT/usr/bin/qemu-arm-static"

# UNMOUNT IMAGE & CLEANUP
# Sync to disc
sync
# Kill remaining processes
kill $(lsof +f -t "$MNT")
# We unmount in reverse order
echo "Unmounting image"
umount "$MNT/sys"
umount "$MNT/proc"
umount -lf "$MNT/dev"
umount "$MNT"
while [[ $(mount | grep "$MNT") ]]
do
echo "Alpine is still mounted, please wait.."
sleep 3
umount "$MNT"
done
echo "Alpine unmounted"

# And remove the apk-tools-static which we extracted to /tmp
echo "Cleaning up"
rm /tmp/apk-tools-static.apk
rm -r /tmp/sbin
