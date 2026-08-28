#!/bin/bash
set -e
: "${DISP:=:99}"
: "${GEOM:=1600x900x24}"
export DISPLAY="$DISP"
Xvfb "$DISP" -screen 0 "$GEOM" -ac -nolisten tcp &
for i in $(seq 1 50); do xdpyinfo -display "$DISP" >/dev/null 2>&1 && break; sleep 0.2; done
openbox &
if [ -n "$VNC_PASSWORD" ]; then
  x11vnc -storepasswd "$VNC_PASSWORD" /tmp/vncpw >/dev/null 2>&1
  AUTH="-rfbauth /tmp/vncpw"
else
  AUTH="-nopw"
fi
x11vnc -display "$DISP" -forever -shared -repeat -rfbport 5900 -localhost $AUTH -quiet &
exec websockify --web /usr/share/novnc 6080 127.0.0.1:5900
