#!/usr/bin/env bash
# dots-relay の準備 (何度動かしてもよい)
#   - ~/.local/lib/dots-relay/venv に dots-bridge (uezo/dots-bridge) を固定のコミットで入れる
#   - ~/.local/lib/dots-relay/tunnel-client に OpenAI の tunnel-client を入れる (SHA256SUMS で確かめる)
#   - ~/.local/state/dots-relay (0700) を作る。鍵や設定はここに置く (~/.config は公開の dotfiles なので置かない)
# 背景は ~/workspace/machine/services/dots-relay.md
set -euo pipefail

STATE=${DOTS_RELAY_STATE:-$HOME/.local/state/dots-relay}
LIB=$HOME/.local/lib/dots-relay
# 版を上げるときは、差分を読んでから書き換える
DOTS_BRIDGE_REF=46010a7bd840ae673cccf432d321e53732243152   # 2026-10-22
TC_VERSION=v0.0.21                                          # 2026-11-14

mkdir -p -m 700 "$STATE"
mkdir -p "$LIB"

uv venv -q --allow-existing "$LIB/venv"
uv pip install -q --python "$LIB/venv/bin/python" "dots-bridge @ git+https://github.com/uezo/dots-bridge@$DOTS_BRIDGE_REF"
echo "dots-bridge: $("$LIB/venv/bin/python" -c 'import importlib.metadata as m; print(m.version("dots-bridge"))') ($DOTS_BRIDGE_REF)"

dest="$LIB/tunnel-client-$TC_VERSION"
if [ ! -x "$dest/tunnel-client" ]; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  zip="tunnel-client-$TC_VERSION-linux-amd64.zip"
  gh release download "$TC_VERSION" --repo openai/tunnel-client --pattern "$zip" --pattern SHA256SUMS.txt --dir "$tmp"
  (cd "$tmp" && grep " $zip\$" SHA256SUMS.txt | sha256sum -c -)
  mkdir -p "$dest"
  unzip -q "$tmp/$zip" -d "$dest"
fi
ln -sfn "tunnel-client-$TC_VERSION" "$LIB/tunnel-client"
echo "tunnel-client: $("$LIB/tunnel-client/tunnel-client" --version)"

if [ ! -f "$STATE/tunnel.env" ]; then
  echo "まだ $STATE/tunnel.env がない。Platform で Tunnel と実行用の API キー (Tunnels の Read と Use) を作り、zsh で次を動かして保存する (bash では read -rp 'tunnel_id: ' T の形にする):"
  echo "  read -r 'T?tunnel_id: ' && read -rs 'K?runtime API key: ' && echo && (umask 077 && printf 'CONTROL_PLANE_TUNNEL_ID=%s\nCONTROL_PLANE_API_KEY=%s\n' \"\$T\" \"\$K\" > $STATE/tunnel.env) && unset K T"
fi
