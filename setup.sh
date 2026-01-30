#!/bin/bash

ln -s $HOME/dotfiles/zsh/.zshrc $HOME/.zshrc
ln -s $HOME/dotfiles/vim/.vimrc $HOME/.vimrc
ln -s $HOME/dotfiles/.config $HOME/.config

# Claude Code settings
mkdir -p $HOME/.claude/scripts $HOME/.claude/commands
ln -sf $HOME/dotfiles/.claude/CLAUDE.md $HOME/.claude/CLAUDE.md
ln -sf $HOME/dotfiles/.claude/settings.json $HOME/.claude/settings.json
for f in $HOME/dotfiles/.claude/scripts/*; do ln -sf "$f" $HOME/.claude/scripts/; done
for f in $HOME/dotfiles/.claude/commands/*; do ln -sf "$f" $HOME/.claude/commands/; done
