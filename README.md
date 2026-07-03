# dotfiles

Ubuntu 環境向けの個人用 dotfiles。シェル・エディタ・ターミナル・Claude Code の設定を一元管理する。
`~/.config` 全体と一部の `~/.claude` 配下を symlink で展開する方式。

## 構成

| パス | 内容 |
|------|------|
| `zsh/` | zsh 設定 (`.zshrc`, `alias.zsh` ほか) |
| `.config/nvim/` | Neovim (lazy.nvim ベース。LSP / markdown プラグイン等) |
| `.config/wezterm/` | WezTerm |
| `.config/zellij/` | Zellij |
| `.config/systemd/user/` | systemd `--user` unit (mutagen-daemon / vllm-tunnel / dns-dangling-monitor) |
| `.config/mimeapps.list` | 既定アプリ (claude-cli URL ハンドラ等) |
| `.claude/` | Claude Code 設定 (`CLAUDE.md`, `settings.json`, `keybindings.json`, `agents/`, `skills/`, `commands/`, `scripts/`) |
| `scripts/` | 補助スクリプト (`dns-dangling-monitor` = DNS 乗っ取り監視 ほか) |
| `app_install.sh` | Ubuntu 向けアプリ導入 (apt) |
| `setup.sh` | dotfiles を `$HOME` へ symlink |

## セットアップ

```bash
# 1. clone (パスは ~/dotfiles 固定。symlink がこのパスを前提とする)
git clone git@github.com:Minto312/dotfiles.git ~/dotfiles

# 2. アプリ導入 (Ubuntu, root 権限が必要)
sudo ~/dotfiles/app_install.sh --console   # 最小構成 (zsh / xsel / neovim)
#   sudo ~/dotfiles/app_install.sh --full   # docker / VS Code / wezterm リポジトリ等も

# 3. symlink を $HOME に展開 (冪等)
~/dotfiles/setup.sh
```

### 4. 手動セットアップ (任意)

資格情報・環境依存のものは自動化していない。詳細は `setup.sh` 末尾のコメント参照。

- **webhook の配置** — `discord-notify` スキルや DNS 監視を使う場合、`~/.config/discord-notify/env` /
  `~/.config/dns-dangling-monitor/env` に webhook URL を書く。
- **systemd `--user` unit の有効化** — 必要な unit だけ `systemctl --user enable --now <unit>` する
  (`~/.config` は symlink 済みなので unit ファイルは配置済み)。

## 管理方針 / 機密の扱い

このリポジトリは **PUBLIC**。以下はコミットしない (`.gitignore` で除外):

- 資格情報 — Bitwarden / gws / MoneyForward / rclone / TigerVNC / webhook / token 埋込の unit 等
- API キーが混入しうるツール設定 — nuclei / subfinder / uncover
- アプリのランタイム状態・キャッシュ — Chrome / draw.io / wrangler / LibreOffice 等のプロファイル

`~/.config` 全体を symlink する都合上、上記もリポジトリのディレクトリ内に実体として存在するが、
git の追跡対象からは外している。新しいマシンでは上記「手動セットアップ」で各マシンローカルに配置する。
