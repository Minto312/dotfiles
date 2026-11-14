---
name: tmux
description: tmux のペインとウィンドウを見る・作る・操作するときの手順と決まり。ペインでコマンドを実行して終わるまで待つ、ペインで Claude を起動して指示を送り・待ち・画面を読む (作業役として動かす) 、エージェントの状態 (@agent_state) を一覧にする、tmux の設定 (~/.config/tmux) を変えて試す、といった作業で使う。ユーザーが tmux・ペイン・ウィンドウ・セッションと言ったとき、tmux の中で作業しているとき ($TMUX がある)、orchestrate スキルで並列に作業するときは、コマンドを打つ前に読む。
---

# tmux — ペインとエージェントの操作

ユーザーは develop の tmux を、lenovo の WezTerm から ssh でつないで使う。設定は `~/.config/tmux/tmux.conf` (dotfiles の `.config/tmux/`)、補助コマンドは `~/.config/tmux/bin/tmux-agents`。

## 運用の決まり

- **セッションは 1 つ (`main`)。** herdr のワークスペースやタブに当たるものは、ウィンドウで分ける。新しい作業は `new-window -t main` で足し、`new-session` は使わない
- **ウィンドウの名前は `<ワークスペース>/<作業>`** (例: `personal/並列作業`)。tmux の対象の指定で区切りに使う `:` と `.` は、名前に入れない
- **試験用の別のサーバー (`tmux -L <名前>`)** は、設定の試験や tmux 本体の開発のときだけ使う。終わったら `kill-server` し、ソケット (`/tmp/tmux-$(id -u)/<名前>`) も消す。既定のサーバーは、ユーザーが使っているので止めない

## 対象の指定

- ペインは **ID (`%12` など) で指定する。** ペインの番号 (`main:2.1`) は、分割や削除で変わる。作るときに `-P -F '#{pane_id}'` で ID を受け取って使う
- 自分のペインは `$TMUX_PANE`。`$TMUX` がなければ tmux の外で動いている
- Claude の Bash には端末がないので、`tmux attach` はできない。画面を見せたいときは、ユーザーに `tmux attach` してもらう
- 対象を省くと、ユーザーが今見ているペインやウィンドウが対象になる。ほかの人のペインを誤って操作しないように、`-t` を必ず付ける

## 見る

```bash
# 全ペインの一覧 (ID、ウィンドウ、前面のコマンド、作業ディレクトリ、エージェントの名前と状態)
tmux list-panes -a -F '#{pane_id} #{window_name} cmd=#{pane_current_command} path=#{pane_current_path} name=#{@agent_name} state=#{@agent_state}'

# エージェントの状態だけ (tmux-agents claude で起動した Claude)
~/.config/tmux/bin/tmux-agents list

# 1 つのペインの値
tmux display -p -t %12 '#{pane_current_command} #{pane_active} #{window_active} #{session_attached}'
```

## 作る

```bash
# 新しいウィンドウ (フォーカスを移さない)
tmux new-window -d -t main -n 'personal/作業名' -c ~/workspace/personal -P -F '#{pane_id}'

# 分割 (フォーカスを移さない)。-h は左右、-v は上下、-l は新しいペインの大きさ
tmux split-window -d -h -l 50% -t %12 -c "$PWD" -P -F '#{pane_id}'
```

- `-d` を付けて、ユーザーの見ている場所を動かさない。`select-window`・`select-pane` も、ユーザーに頼まれたときだけ使う
- 作業ディレクトリは `-c` で渡す。付けないと、ペインごとに違う場所で始まる

## コマンドを実行して待つ

```bash
ch="done-${pane#%}-$$"
tmux send-keys -t "$pane" -l "make test; tmux wait-for -S $ch"
tmux send-keys -t "$pane" Enter
timeout 600 tmux wait-for "$ch"    # 終わるまで待つ (時間切れなら 124 で終わる)
tmux capture-pane -p -J -t "$pane" -S -200
```

- `send-keys -l` は文字をそのまま送る (キーの名前として解釈しない)。Enter は別に送る
- 終わりの合図は `wait-for -S` で送る。画面を何度も読んで待つより確実

## Claude を作業役として動かす

`tmux-agents claude` で起動した Claude は、フックでペインの `@agent_state` に状態を書き込む。値は `working` (作業中)・`blocked` (確認や質問の画面で止まっている)・`done` (見ていないうちに終わった)・`idle` (待機)。

```bash
# 状態を待つ関数: wait_state <ペイン> <秒> <状態...>。どれかになれば 0、時間切れなら 1 で終わる
wait_state() { local p=$1 t=$2; shift 2; local end=$((SECONDS + t)) s w
  while ((SECONDS < end)); do s=$(tmux display -p -t "$p" '#{@agent_state}')
    for w in "$@"; do [ "$s" = "$w" ] && return 0; done; sleep 2; done; return 1; }

# 起動する。オプションはユーザーが普段使っているもの (ps -eo args | grep claude で確かめる)
tmux set -p -t "$pane" @agent_name w1
tmux send-keys -t "$pane" -l "~/.config/tmux/bin/tmux-agents claude --effort xhigh --dangerously-skip-permissions"
tmux send-keys -t "$pane" Enter
wait_state "$pane" 60 idle          # 起動すると idle になる

# 指示を送る。長い文や複数行は、ファイルからバッファに入れて括弧付きで貼り付けてから Enter
tmux set -p -t "$pane" @agent_state sent   # 送ったことの印。フックが working・idle・done に書き換える
tmux load-buffer -b "w1-prompt" /path/to/brief.md
tmux paste-buffer -p -d -b "w1-prompt" -t "$pane"
sleep 1
tmux send-keys -t "$pane" Enter

# 終わるまで待つ (送る前に sent にしたので、すぐ終わっても見逃さない。sent のまま時間切れなら、送れていない)
wait_state "$pane" 3600 idle done blocked

# 画面を読む
tmux capture-pane -p -J -t "$pane"

# 終了する (作業中なら先に Escape で止める)
tmux send-keys -t "$pane" Escape
tmux send-keys -t "$pane" -l "/exit"
tmux send-keys -t "$pane" Enter
```

- 待つ処理は、Bash の `run_in_background` で動かし、終わった知らせを受けてから読む
- **Claude Code は代替画面を使うので、`capture-pane` で読めるのは見えている画面だけ** (履歴は 0 行)。画面から消えた返答は読めない。長い報告は PR の本文やファイルに書かせ、そちらを読む
- `blocked` は、確認や質問の画面で止まっている。`capture-pane` で画面を読んでから、どう答えるかを決める (自分で決められなければユーザーに聞く)
- `send-keys` で指示を送るのは、自分が起動した作業役のペインだけにする。ユーザーが使っているペイン (`pane_active` と `window_active` が 1 で、`session_attached` が 1 以上) や、入力欄にユーザーの入力があるペインには送らない
- 素の `claude` で起動した Claude には `@agent_state` が付かない (状態は分からない)

## 閉じる

- 自分が作ったペインとウィンドウだけを閉じる (`kill-pane -t %12`、`kill-window -t <ID>`)。ユーザーのものは、頼まれたときだけ閉じる
- `kill-server` は、試験用のサーバーにだけ使う

## 設定を変える

- 設定は dotfiles の `.config/tmux/tmux.conf` にあり、変更は dotfiles の worktree で行って PR を出す
- 試すときは、試験用のサーバーで読み込ませる: `tmux -L <名前> -f <worktree>/.config/tmux/tmux.conf new-session -d -s main`
- 動いているサーバーに反映するには `tmux source-file ~/.config/tmux/tmux.conf`
