# ~/.claude/CLAUDE.md

## 開発ワークフロー
はじめに，`git pull`を行いブランチを最新の状態にしてください．

ファイルに変更を加える際には，.claude/ 以下にworktree を切って作業を行い，常に並列に作業できるようにしてください．

コードの実装を完了したら，reviewerエージェントを使用してdiffをレビューすること．

以下のような文言をコミットメッセージ，PRに含めないでください．
```
🤖 Generated with Claude Code
Co-Authored-By: Claude Opus 4.5 noreply@anthropic.com
```
