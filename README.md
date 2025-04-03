# HAOS-kiosk
Display HA dashboards in kiosk mode directly on your HAOS server

## Author: Jeff Kosowsky

## Description
Launch X windows on local HAOS server followed by OpenBox window manager and Luakit browser.<br>
Standard mouse and keyboard interactions should work automatically

Note: that Luakit is launched in kiosk-like (*passthrough*) mode.<br>
To enter *normal* mode (similar to command mode in vi), press `ctl-alt-esc`<br>
You can then return to *passthrough* mode by pressing `ctl-Z` or enter *insert* mode by pressing `i`<br>
See luakit documentation for available commands.<br>
In general, you want to stay in `passthrough` mode<br>

## Configuration Options
### HA Username [required]
Enter your Home Assistant login name
### HA Password [required]
Enter your Home Assistant password
### HA URL
Default is: `http://localhost:8123`<br>
In general, you shouldn't need to change this since this is running on the local server.
### HA Dashboard
Name of starting dashboard.<br>
Defaults to "" which loads the default `Lovelace` dashboard.
### Login Delay
Delay in seconds to allow login page to load.<br>
Defaults to `1` second.
### HDMI Port
HDMI output port. Technically can be `0` or `1` (Defaults to `0`).<br>
BUT currently has no effect on stock HAOS on RPi since configured to mirror HDMI0 onto HDMI1.
### Screen Timeout
Time before screen blanks in seconds. Set to `0` to never timeout.<br>
Default is `600` seconds.
### Browser Refresh
Time between browser refreshes. Set to `0` to disable.<br>
Recommended since on default RPi config, console errors *may* overwrite the dashboard.<br>
Default is `600` seconds.
### Zoom Level
Level of zoom with `100` being 100%. <br>
Defaults is `100`.
