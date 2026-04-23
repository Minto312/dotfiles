#!/bin/bash

ln -s $HOME/dotfiles/zsh/.zshrc $HOME/.zshrc
ln -s $HOME/dotfiles/vim/.vimrc $HOME/.vimrc
ln -s $HOME/dotfiles/.config $HOME/.config

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
