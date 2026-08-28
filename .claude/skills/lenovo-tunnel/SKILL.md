---
name: lenovo-tunnel
description: develop 上の loopback ポートを、ユーザーの手元のマシン (lenovo) の localhost へ SSH リバーストンネルで通し、必要なら手元の既定ブラウザで開く。develop で立てた開発サーバ・プレビュー・ビューア・noVNC・管理画面などを「手元で見たい」と言われたとき、または画面を見てもらう必要があるときに使う。develop 側から張るのでユーザー側の設定は一切要らない。「手元で見せて」「ブラウザで開いて」「localhost に通して」「ポートフォワードして」「画面を見たい」などで起動。
allowed-tools: Bash
---

# lenovo-tunnel

develop は SSH 先の VM なので、そこで立てたサーバはユーザーのブラウザからは見えない。
このスキルは **develop 側から** リバーストンネルを張って、`lenovo` (ユーザーの ThinkPad) の
`localhost:<port>` に develop のポートを生やす。ユーザー側の操作は不要。

```
develop 127.0.0.1:<dport>  ──ssh -R──>  lenovo localhost:<lport>
```

## 使い方

```bash
~/dotfiles/scripts/lenovo-tunnel/lenovo-tunnel up 5173          # 同じ番号で通す
~/dotfiles/scripts/lenovo-tunnel/lenovo-tunnel up 3000:8080     # lenovo:3000 → develop:8080
~/dotfiles/scripts/lenovo-tunnel/lenovo-tunnel open 5173 /docs  # 通して既定ブラウザで開く
~/dotfiles/scripts/lenovo-tunnel/lenovo-tunnel list             # 現在の一覧
~/dotfiles/scripts/lenovo-tunnel/lenovo-tunnel down 5173        # 個別に切る
~/dotfiles/scripts/lenovo-tunnel/lenovo-tunnel down --all       # 全部切る
```

## いつ使うか

**使う**:

- develop で dev server / プレビュー / ビューアを立てて、ユーザーに見てもらいたいとき
- スクリーンショットでは足りず、ユーザー自身に操作してほしいとき (ログイン、CAPTCHA、目視確認)
- `shared-browser` の noVNC を見せるとき (shared-browser 自身がこのスクリプトを呼ぶ)

**使わない**:

- 恒常的に公開したいもの → **Tailscale Services** にする (grafana / feedscope / home が前例)。
  スマホからも見られるし、develop の SSH セッションに依存しない
- develop の中だけで完結する確認 → Playwright MCP でスクリーンショットを撮れば足りる

## 判断の指針

- **ユーザーに見せたいものができたら、URL を書くだけで終わらせずトンネルを張る**。
  develop の `http://localhost:xxxx` はユーザーのブラウザからは開けない
- 開いたら **何番で見られるか**を必ず伝える。衝突時は番号が振り替わる (下記)
- 用が済んだら `down` する。張りっぱなしは SSH セッションを持ち続ける

## 注意

- 🔴 **Windows の sshd はリモート forward の bind 失敗を報告しない**。`ExitOnForwardFailure`
  を付けても、lenovo で使用中のポートを要求して rc=0 が返る (実測)。放置すると手元の
  サービスのポートを黙って奪いかねないので、スクリプトが **張る前に lenovo の listen 一覧を
  見て衝突を避け、張った後に listen へ現れたかを検証**している。この 2 段を飛ばして
  素の `ssh -R` を叩かないこと
- 衝突したポートは `18000` から順に空きを探して**自動で振り替える**。`ok` 行に実際の番号が出る
- develop 側で誰も listen していないポートを指定すると `warn` が出る (指定ミスの検出)
- lenovo の loopback にしか出ない (Windows sshd の `GatewayPorts` 既定 no)。LAN には露出しない
- 接続先は `LT_CLIENT_HOST` で変えられる (既定 `lenovo`)

背景と実測は `~/workspace/machine/dev/lenovo-tunnel.md`。
