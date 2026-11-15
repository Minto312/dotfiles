# ~/.claude/CLAUDE.md

## 資料

最終的に人に見せる資料 (HTML の artifact・PDF・Docs・スライド) を作る (直す) ときは，どのワークスペースでも作り始める前に `documentation` スキルを読んでください．

## ブラウザ

ブラウザを使う (Playwright MCP の `browser_*` ツールを呼ぶ，Web ページを開く・操作する，人にログインしてもらう) ときは，どのワークスペースでも始める前に `browser` スキルを読んでください．

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
