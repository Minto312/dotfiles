#!/bin/bash

ln -sfn $HOME/dotfiles/zsh/.zshrc $HOME/.zshrc
ln -sfn $HOME/dotfiles/.config $HOME/.config

# Claude Code settings
# ~/.claude 配下のうちバージョン管理対象のみ dotfiles へ symlink する。
# history.jsonl / sessions/ / projects/ / cache/ などのランタイム状態は各マシンローカルのまま残す。
mkdir -p $HOME/.claude
ln -sfn $HOME/dotfiles/.claude/CLAUDE.md $HOME/.claude/CLAUDE.md
ln -sfn $HOME/dotfiles/.claude/settings.json $HOME/.claude/settings.json
ln -sfn $HOME/dotfiles/.claude/keybindings.json $HOME/.claude/keybindings.json
for d in agents commands scripts skills; do
    # 既存が実ディレクトリの場合は symlink に置き換え前に退避が必要なため警告して skip
    if [ -d "$HOME/.claude/$d" ] && [ ! -L "$HOME/.claude/$d" ]; then
        echo "warn: $HOME/.claude/$d is a real directory; move its contents into dotfiles and remove it, then re-run." >&2
        continue
    fi
    ln -sfn "$HOME/dotfiles/.claude/$d" "$HOME/.claude/$d"
done

# --- 手動セットアップ (gitignore 済みの資格情報・環境依存のため自動化しない) ---
#
# discord-notify スキルを使う場合は webhook を配置する:
#   mkdir -p ~/.config/discord-notify
#   echo "DISCORD_WEBHOOK_URL='https://discord.com/api/webhooks/...'" > ~/.config/discord-notify/env
#
# resource-audit の通知を別チャンネルに出す場合 (省略すると上の discord-notify と同じ宛先):
#   mkdir -p ~/.config/resource-audit && chmod 700 ~/.config/resource-audit
#   echo "DISCORD_WEBHOOK_URL='https://discord.com/api/webhooks/...'" > ~/.config/resource-audit/env
#
# ドメイン監視 (domain-monitor) は資格情報を持たない。OTLP を吐くだけで、
# 閾値判定と Discord 通知は observability 基盤の Grafana Alerting 側にある。
#
# Drive → tl;dv の自動取り込み (tldv-ingest) を使う場合:
#   mkdir -p ~/.config/tldv-ingest && chmod 700 ~/.config/tldv-ingest
#   cp ~/dotfiles/scripts/tldv-ingest/env.example ~/.config/tldv-ingest/env
#   chmod 600 ~/.config/tldv-ingest/env   # API キーと Drive のフォルダ ID を埋める
#
# systemd --user unit を有効化する (必要なものだけ。~/.config は symlink 済みなのでファイルは配置済み):
#   systemctl --user daemon-reload
#   systemctl --user enable --now domain-monitor-check.timer   # 到達性/TLS/DNS drift (5 分毎)
#   systemctl --user enable --now domain-monitor-audit.timer   # サブドメイン列挙と乗っ取り走査 (日次)
#   systemctl --user enable --now tldv-ingest.timer            # Drive の受け皿 → tl;dv (5 分毎)
#   systemctl --user enable --now mutagen-daemon.service
#   systemctl --user enable --now resource-audit-collect.timer   # リソース棚卸しの日次収集
#   systemctl --user enable --now resource-audit-report.timer    # 週次レポート (herdr ペインを立てる)
#   # vllm-tunnel は gpu-soroban への SSH 到達性がある環境でのみ enable する
#   # openclaw-gateway は token 埋込のため管理外 (各マシンでローカル配置)
