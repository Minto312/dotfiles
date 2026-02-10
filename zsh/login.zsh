# login.zsh - ログイン時の情報表示

# 対話シェルかつSSH接続またはローカルログイン時のみ表示
if [[ -o interactive ]] && [[ -z "$TMUX" || -n "$SSH_CONNECTION" ]]; then
    if command -v fastfetch &> /dev/null; then
        fastfetch
    fi
fi
