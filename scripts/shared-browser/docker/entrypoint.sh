#!/bin/bash
set -e
: "${DISP:=:99}"
: "${GEOM:=1600x900x24}"
: "${IME:=1}"
export DISPLAY="$DISP"
Xvfb "$DISP" -screen 0 "$GEOM" -ac -nolisten tcp &
for i in $(seq 1 50); do xdpyinfo -display "$DISP" >/dev/null 2>&1 && break; sleep 0.2; done
openbox &

# 日本語 IME (fcitx5 + anthy)。ホストの Chrome へは XIM で繋がる。
# 🔴 **Chrome より先に起動していること**が必須。XIM クライアントは起動時に
#    サーバを探しに行くので、あとから fcitx5 を立てても繋がらない (実測)。
#    shared-browser の cmd_up は「コンテナを待ってから Chrome」なので順序は満たされる。
if [ "$IME" = 1 ]; then
	# ⚠ ja_JP.UTF-8 でないと Xlib の XIM が黙って無効になる (C.UTF-8 は不可)
	export LANG=ja_JP.UTF-8 LC_CTYPE=ja_JP.UTF-8
	mkdir -p /root/.config/fcitx5
	# 入力メソッドは「英数 (keyboard-us)」と「anthy」の 2 つ。
	# 切り替えは画面で **Ctrl+Space**。noVNC 越しでも効く (Ctrl と Space が
	# 完全に同時 = 間隔 0 のときだけ効かないが、人間の指では必ず空く)。
	# 手元の OS/IME に横取りされる場合は `shared-browser ime {on|off}`。
	cat >/root/.config/fcitx5/profile <<-'PROF'
		[Groups/0]
		Name=Default
		Default Layout=us
		DefaultIM=anthy

		[Groups/0/Items/0]
		Name=keyboard-us
		Layout=

		[Groups/0/Items/1]
		Name=anthy
		Layout=

		[GroupOrder]
		0=Default
	PROF
	# 既定は英数にする (URL バーまでかなになると邪魔なので)
	printf '[Behavior]\nActiveByDefault=False\n' >/root/.config/fcitx5/config
	# ⚠ fcitx5 は D-Bus セッションバスを要求する。ホストのバスは借りず
	#   コンテナ内に専用のものを立てる (経路を跨がせない)。
	export DBUS_SESSION_BUS_ADDRESS="unix:path=/tmp/fcitx5-bus"
	rm -f /tmp/fcitx5-bus
	dbus-daemon --session --fork --address="$DBUS_SESSION_BUS_ADDRESS"
	fcitx5 --disable=wayland,waylandim >/tmp/fcitx5.log 2>&1 &
	# XIM サーバが X に登録されるまで待つ (Chrome より先に居ることの保証)
	for i in $(seq 1 50); do
		xprop -root XIM_SERVERS 2>/dev/null | grep -q '@server=fcitx' && break
		sleep 0.2
	done
fi

if [ -n "$VNC_PASSWORD" ]; then
  x11vnc -storepasswd "$VNC_PASSWORD" /tmp/vncpw >/dev/null 2>&1
  AUTH="-rfbauth /tmp/vncpw"
else
  AUTH="-nopw"
fi
x11vnc -display "$DISP" -forever -shared -repeat -rfbport 5900 -localhost $AUTH -quiet &
exec websockify --web /usr/share/novnc 6080 127.0.0.1:5900
