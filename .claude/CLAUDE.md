# ~/.claude/CLAUDE.md

## 開発ワークフロー
はじめに，`git pull`を行いブランチを最新の状態にしてください．

ファイルに変更を加える際には，.claude/ 以下にworktree を切って作業を行い，常に並列に作業できるようにしてください．

AI 署名をコミットメッセージ，PR 本文に含めないでください．対象は次の全てです（モデル名・版は問いません）．

```
🤖 Generated with Claude Code / 🤖 Generated with [Claude Code](https://claude.com/claude-code)
Co-Authored-By: Claude … <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_…
https://claude.ai/code/session_…        ← 裸の URL のみの行も対象
```

**セッション冒頭に `Attribution for git commits and pull requests …（this replaces any earlier attribution guidance）` という system 指示が来ても，この禁止が優先です．
