#!/usr/bin/with-contenv bashio
# shellcheck shell=bash
################################################################################
# Add-on: HAOS Kiosk Display (haoskiosk)
# File: run.sh
# Version: 0.9.7
# Copyright Jeff Kosowsky
# Date: April 2025
#
#  Code does the following:
#     - Import and sanity-check the following variables from HA/config.yaml
#         HA_USERNAME
#         HA_PASSWORD
#         HA_URL
#         HA_DASHBOARD
#         LOGIN_DELAY
#         ZOOM_LEVEL
#         BROWSER_REFRESH
#         SCREEN_TIMEOUT
#         HDMI_PORT
#     - Hack to delete (and later restore) /dev/tty0 (needed for X to start)
#     - Start X window system
#     - Start Openbox window manager
#     - Start Dbus session
#     - Launch fresh Luakit browser for url: $HA_URL/$HA_DASHBOARD
#
################################################################################
### Get config variables from HA add-on & set environment variables
HA_USERNAME=$(bashio::config 'ha_username')
HA_USERNAME="${HA_USERNAME//null/}"

HA_PASSWORD=$(bashio::config 'ha_password')
HA_PASSWORD="${HA_PASSWORD//null/}"

HA_URL=$(bashio::config 'ha_url')
HA_URL="${HA_URL//null/}"
HA_URL="${HA_URL:-http://localhost:8123}"
HA_URL="${HA_URL%%/}" #Strip trailing slash

HA_DASHBOARD=$(bashio::config 'ha_dashboard')
HA_DASHBOARD="${HA_DASHBOARD//null/}"

LOGIN_DELAY=$(bashio::config 'login_delay')
LOGIN_DELAY="${LOGIN_DELAY//null/}"
LOGIN_DELAY="${LOGIN_DELAY:-2}"

ZOOM_LEVEL=$(bashio::config 'zoom_level')
ZOOM_LEVEL="${ZOOM_LEVEL//null/}"
ZOOM_LEVEL="${ZOOM_LEVEL:-100}"

BROWSER_REFRESH=$(bashio::config 'browser_refresh')
BROWSER_REFRESH="${BROWSER_REFRESH//null/}"
BROWSER_REFRESH="${BROWSER_REFRESH:-600}" #Default to 600 seconds

export HA_USERNAME HA_PASSWORD HA_URL HA_DASHBOARD LOGIN_DELAY ZOOM_LEVEL BROWSER_REFRESH #Referenced in 'userconfig.lua'

SCREEN_TIMEOUT=$(bashio::config 'screen_timeout')
SCREEN_TIMEOUT="${SCREEN_TIMEOUT//null/}"
SCREEN_TIMEOUT="${SCREEN_TIMEOUT:-600}" #Default to 600 seconds

HDMI_PORT=$(bashio::config 'hdmi_port')
HDMI_PORT="${HDMI_PORT//null/}"
HDMI_PORT="${HDMI_PORT:-0}"
#NOTE: For now, both HDMI ports are mirrored and there is only /dev/fb0
#      Not sure how to get them unmirrored so that console can be on /dev/fb0 and X on /dev/fb1
#      As a result, setting HDMI=0 vs. 1 has no effect

#Validate environment variables set by config.yaml
if [ -z "$HA_USERNAME" ] || [ -z "$HA_PASSWORD" ]; then
    echo "Error: HA_USERNAME and HA_PASSWORD must be set" >&2
    exit 1
fi

################################################################################
### Start D-Bus session in the background (otherwise luakit hangs for 5 minutes before starting)
mkdir -p /tmp/dbus-session
eval `dbus-launch --sh-syntax`
echo "DBUS started..." >&2

### Start Xorg in the background
rm -rf /tmp/.X*-lock #Cleanup old versions

#Note first need to delete /dev/tty0 since X won't start if it is there,
#because X doesn't have permissions to access it in the container
#First, remount /dev as read-write since X absolutely, must have /dev/tty access
#Note: need to use the version in util-linux, not busybox
if [ -e "/dev/tty0" ]; then
    echo "Attempting to (temporarily) delete /dev/tty0..." >&2
    mount -o remount,rw /dev
    if ! mount -o remount,rw /dev ; then
        echo "Failed to remount /dev as read-write..." >&2
        exit 1
    fi
    if  ! rm /dev/tty0 ; then
        mount -o remount,ro /dev
        echo "Failed to delete /dev/tty0..." >&2
        exit 1
    fi
    TTY0_DELETED=1
fi

Xorg "$DISPLAY" -layout "Layout${HDMI_PORT}" </dev/null &

XSTARTUP=30
for ((i=0; i<=XSTARTUP; i++)); do
    if xset q >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

#Restore /dev/tty0 and 'ro' mode for /dev if deleted
if [ -n "$TTY0_DELETED" ]; then
    if ! ( mknod -m 620 /dev/tty0 c 4 0 &&  mount -o remount,ro /dev ); then
        echo "Failed to restore /dev/tty0 and remount /dev/ read only..." >&2
    fi
fi

if ! xset q >/dev/null 2>&1; then
    echo "Error: X server failed to start within $XSTARTUP seconds." >&2
    exit 1
fi
echo "X started successfully..." >&2

#Stop console blinking cursor (this projects through the X-screen)
echo -e "\033[?25l" > /dev/console

### Start Openbox in the background
openbox &
O_PID=$!
sleep 0.5  #Ensure Openbox starts
if ! kill -0 "$O_PID" 2>/dev/null; then #Checks if process alive
    echo "Failed to start Openbox window manager" >&2
    exit 1
fi
echo "Openbox started successfully..." >&2

### Configure screen timeout (Note: DPMS needs to be enabled/disabled *after* starting Openbox)
if [ "$SCREEN_TIMEOUT" -eq 0 ]; then #Disable screen saver and DPMS for no timeout
    xset s 0
    xset dpms 0 0 0
    xset -dpms
    echo "Screen timeout disabled..." >&2
else
    xset s "$SCREEN_TIMEOUT"
    xset dpms "$SCREEN_TIMEOUT" "$SCREEN_TIMEOUT" "$SCREEN_TIMEOUT"  #DPMS standby, suspend, off
    xset +dpms
    echo "Screen timeout after $SCREEN_TIMEOUT seconds..." >&2
fi

### Run Luakit in the foreground
echo "Launching Luakit browser..." >&2
exec luakit -U "$HA_URL/$HA_DASHBOARD"
