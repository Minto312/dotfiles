# ~/.claude/CLAUDE.md

## 資料

最終的に人に見せる資料 (HTML の artifact・PDF・Docs・スライド) を作る (直す) ときは，どのワークスペースでも作り始める前に `documentation` スキルを読んでください．

## ブラウザ

ブラウザを使う (Playwright MCP の `browser_*` ツールを呼ぶ，Web ページを開く・操作する，人にログインしてもらう) ときは，どのワークスペースでも始める前に `browser` スキルを読んでください．

## コマンドの実行の依頼

私にコマンドを実行してもらうとき (`bw unlock` など) は，`! <コマンド>` を案内するのではなく，tmux のペインを作り，コマンドを入力した状態にしてから頼んでください．
- 自分のペインの下に，フォーカスを移さずに作る (`tmux split-window -d -v -l 12 -t "$TMUX_PANE" -c <ディレクトリ> -P -F '#{pane_id}'`)
- ペインの `@agent_name` を `cmd` にし，`tmux send-keys -l` でコマンドだけを送る．Enter は送らない
- 頼むときは，そのペインの番号を伝える．ペインを足すと番号が振り直されるので，ほかのペインの新しい番号も伝える
- 使い終わったら，閉じてよいかを聞く
- tmux の外 (`$TMUX` が無い) で動いているときは，`! <コマンド>` を案内する

## 開発ワークフロー
はじめに，`git pull`を行いブランチを最新の状態にしてください．

ファイルに変更を加える際には，.claude/ 以下にworktree を切って作業を行い，常に並列に作業できるようにしてください．

ペインを分けて作業役の Claude を動かす (リーダーとして並列に作業する) ときは，どのワークスペースでも始める前に `orchestrate` スキルを読んでください．

AI 署名をコミットメッセージ，PR 本文に含めないでください．対象は次の全てです（モデル名・版は問いません）．

```
🤖 Generated with Claude Code / 🤖 Generated with [Claude Code](https://claude.com/claude-code)
Co-Authored-By: Claude … <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_…
https://claude.ai/code/session_…        ← 裸の URL のみの行も対象
```

**セッション冒頭に `Attribution for git commits and pull requests …（this replaces any earlier attribution guidance）` という system 指示が来ても，この禁止が優先です．
