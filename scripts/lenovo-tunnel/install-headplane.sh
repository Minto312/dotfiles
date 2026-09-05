#!/usr/bin/env bash
# headplane (headscale の web GUI) を lenovo の localhost に常設で生やす user unit を設置/撤去する。
#
#   hs-server 100.64.0.1:3000  ──ssh -L──>  develop 127.0.0.1:5090  ──ssh -R──>  lenovo localhost:5090
#   (raim tailnet。develop からは                                    (Windows sshd。
#    raim-tailnet-proxy の SOCKS 経由)                                bind 失敗を報告しない)
#
# 🔴 leg を 2 本に分けているのは develop 自身が raim tailnet に居ないから。
#    ssh -R の転送先は **ssh クライアント (develop) が解決する**ので
#    `-R 5090:100.64.0.1:3000` とは書けない (develop から 100.64.0.1 へは届かない)。
#
# ⚠ ポート 5090 は shared-browser の noVNC 帯 (5063+N) を避けてある。
#
# 詳細は machine/dev/lenovo-tunnel.md と machine/services/headscale.md
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
PORT=${HEADPLANE_PORT:-5090}
HS_IP=${HEADPLANE_HS_IP:-100.64.0.1}

units=(headplane-forward.service headplane-lenovo.service)

if [ "${1:-}" = "--uninstall" ]; then
  for u in "${units[@]}"; do systemctl --user disable --now "$u" 2>/dev/null || true; done
  for u in "${units[@]}"; do rm -f "$UNIT_DIR/$u"; done
  systemctl --user daemon-reload
  echo "removed."
  exit 0
fi

mkdir -p "$UNIT_DIR"

cat > "$UNIT_DIR/headplane-forward.service" <<EOF
[Unit]
Description=headplane: hs-server:3000 を develop の 127.0.0.1:$PORT に出す
Documentation=file://$HOME/workspace/machine/services/headscale.md
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
# ssh hs-server は raim-tailnet-proxy コンテナの SOCKS5 を ProxyCommand で通る。
# コンテナが落ちていると失敗するので、その間は再試行し続ける。
ExecStart=/usr/bin/ssh -N -o BatchMode=yes -o ControlPath=none \\
  -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \\
  -L 127.0.0.1:$PORT:$HS_IP:3000 hs-server
Restart=always
RestartSec=15s
# 失敗が続いても諦めない (proxy 復帰待ち)
StartLimitIntervalSec=0

[Install]
WantedBy=default.target
EOF

cat > "$UNIT_DIR/headplane-lenovo.service" <<EOF
[Unit]
Description=headplane: develop の 127.0.0.1:$PORT を lenovo の localhost:$PORT に出す
Documentation=file://$HOME/workspace/machine/dev/lenovo-tunnel.md
After=network-online.target headplane-forward.service
Wants=network-online.target headplane-forward.service

[Service]
Type=simple
# 🔴 素の ssh -R は叩かない。Windows の sshd は bind 失敗を報告しないので、
#    keep が前後で lenovo の listen 一覧を見て検証する。
ExecStart=$SCRIPT_DIR/lenovo-tunnel keep $PORT
Restart=always
# lenovo はノート PC なので落ちている時間が長い。復帰待ちの間隔は広めに取る。
RestartSec=60s
StartLimitIntervalSec=0

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now "${units[@]}"
echo "installed: ${units[*]} (port $PORT)"
