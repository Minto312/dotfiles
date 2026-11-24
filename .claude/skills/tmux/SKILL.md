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
- develop を再起動すると、tmux-resurrect がウィンドウとペインを戻し、Claude は同じ会話を開き直す。ただし、ペインの ID は振り直され、ペインのオプション (`@agent_name` など) は戻らない。再起動の前に覚えた ID は使わず、`list-panes` で引き直す
- 自分のペインは `$TMUX_PANE`。`$TMUX` がなければ tmux の外で動いている
- Claude の Bash には端末がないので、`tmux attach` はできない。画面を見せたいときは、ユーザーに `tmux attach` してもらう
- 対象を省くと、ユーザーが今見ているペインやウィンドウが対象になる。ほかの人のペインを誤って操作しないように、`-t` を必ず付ける

## 見る

```bash
# 全ペインの一覧 (ID、ウィンドウ、前面のコマンド、作業ディレクトリ、エージェントの名前と状態)
tmux list-panes -a -F '#{pane_id} #{window_name} cmd=#{pane_current_command} path=#{pane_current_path} name=#{@agent_name} state=#{@agent_state}'

# エージェントの状態だけ
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

Claude は、全体の設定 (`~/.claude/settings.json`) のフックで、ペインの `@agent_state` に状態を書き込む (どう起動しても付く)。値は `working` (作業中)・`blocked` (確認や質問の画面で止まっている)・`done` (見ていないうちに終わった)・`idle` (待機)。

- 例外として、リーダーの巡回の回 (プロンプトが `[巡回]` で始まる回。`orchestrate` スキル) は、状態を変えず、スマホにも知らせない。巡回の中でリーダーがペインの `@patrol_report` を付けたときだけ、普段の回と同じに扱う。そのため、リーダーが応答の途中かどうかは、`@agent_state` ではなく `~/.claude/sessions/<pid>.json` の `status` (`busy`) で見る
- 複数の作業役を 1 つの処理で待つときは、下の `wait_state` ではなく `~/.config/tmux/bin/tmux-agents wait <秒> <ペイン>...` を使う (どれかが `idle`・`done`・`blocked` になるか、ペインが無くなると終わる)

```bash
# 状態を待つ関数: wait_state <ペイン> <秒> <状態...>。どれかになれば 0、時間切れなら 1 で終わる
wait_state() { local p=$1 t=$2; shift 2; local end=$((SECONDS + t)) s w
  while ((SECONDS < end)); do s=$(tmux display -p -t "$p" '#{@agent_state}')
    for w in "$@"; do [ "$s" = "$w" ] && return 0; done; sleep 2; done; return 1; }

# 起動する。--effort は作業の難しさで決める (orchestrate スキル)。ほかのオプションはユーザーが普段使っているもの (ps -eo args | grep claude で確かめる)
tmux set -p -t "$pane" @agent_name a1
tmux send-keys -t "$pane" -l "claude --effort high --dangerously-skip-permissions"
tmux send-keys -t "$pane" Enter
wait_state "$pane" 60 idle          # 起動すると idle になる

# 指示を送る。長い文や複数行は、ファイルからバッファに入れて括弧付きで貼り付けてから Enter
tmux set -p -t "$pane" @agent_state sent   # 送ったことの印。フックが working・idle・done に書き換える
tmux load-buffer -b "a1-prompt" /path/to/brief.md
tmux paste-buffer -p -d -b "a1-prompt" -t "$pane"
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

# 同じ会話のまま再起動する (effort を変えるとき、設定や CLAUDE.md を読み直させるとき)。
# 待機になり、Bash ツールの処理が残っておらず、ユーザーが使っていないのを待ってから /exit し、
# 同じペインで claude --resume <会話の ID> [--effort <段階>] を打つ。結果を 1 行出す (run_in_background で動かす)
~/.config/tmux/bin/tmux-agents restart "$pane" xhigh   # effort を変える。keep は今のまま、default は既定
```

- Bash の `run_in_background` の処理や `CronCreate` の予定が残っている Claude に `/exit` を送ると、「Background work is running」の確認の画面が出て、終了しない (2.1.331)。`1. Exit and stop tasks` (初めから選ばれている) を Enter で選ぶと、それらを止めて終了する。Escape は `3. Stay` と同じで、終了しない
- zsh の別名 `claude` は、先に `--effort high` を付ける。`--effort` が 2 つあると後に書いたほうが効くので、送ったコマンドの `--effort` が使われる (2026-11-20 に、会話の記録 (JSONL) の各応答の `"effort"` で確かめた)
- `tmux-agents restart` は、会話の ID を `~/.claude/sessions/<pid>.json` から、今の effort を会話の記録から取る。どちらも Claude Code の文書に書かれていない内部のファイルで、更新で変わることがある
- すべての Claude をまとめて再起動するときは、`restart-claude` スキルを使う
- 待つ処理は、Bash の `run_in_background` で動かし、終わった知らせを受けてから読む
- 全体の設定で Claude Code の代替画面を切ってある (`CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1`) ので、`capture-pane -p -J -t "$pane" -S -<行数>` で画面から消えた返答も読める。この設定より前に起動した Claude は代替画面のままで、見えている画面しか読めない (`#{alternate_on}` が 1、`#{history_size}` が 0)。長い報告は PR の本文やファイルに書かせ、そちらを読む
- `blocked` は、確認や質問の画面で止まっている。`capture-pane` で画面を読んでから、どう答えるかを決める (自分で決められなければユーザーに聞く)
- Claude のペインに文を送る前に、`tmux display -p -t "$pane" '#{pane_current_command}'` が `claude` であることを確かめる。再起動の途中などで前面がシェル (`zsh`・`bash`) に戻っていると、シェルがその文を実行する
- `send-keys` で指示を送るのは、自分が起動した作業役のペインだけにする。ユーザーが使っているペイン (`pane_active` と `window_active` が 1 で、`session_attached` が 1 以上) や、入力欄にユーザーの入力があるペインには送らない

## 閉じる

- 自分が作ったペインとウィンドウだけを閉じる (`kill-pane -t %12`、`kill-window -t <ID>`)。ユーザーのものは、頼まれたときだけ閉じる
- `kill-server` は、試験用のサーバーにだけ使う

## 設定を変える

- 設定は dotfiles の `.config/tmux/tmux.conf` にあり、変更は dotfiles の worktree で行って PR を出す
- 試すときは、試験用のサーバーで読み込ませる: `tmux -L <名前> -f <worktree>/.config/tmux/tmux.conf new-session -d -s main`
- 再起動のあとに戻すプラグイン (tmux-resurrect と tmux-continuum、`bin/tmux-restore`) は、既定のサーバーでだけ読む。プラグインのスクリプト (`save.sh`・`restore.sh` など) は `-L` を受け取らず、環境変数 `TMUX` のサーバーを操作する。Claude の Bash から直接動かすと、既定のサーバーを保存・復元してしまう。試すときは、試験用のサーバーの `run-shell` から動かし、`-L <名前>` を付けて実行する `tmux` を PATH の先頭に置く
- 動いているサーバーに反映するには `tmux source-file ~/.config/tmux/tmux.conf`
