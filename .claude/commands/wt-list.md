# Worktree一覧表示スキル

現在のリポジトリに関連する全worktreeの一覧と各worktreeのステータスを表示する。

## 前提条件

- 現在のディレクトリがgitリポジトリ内であること

## 手順

### 1. worktree一覧の取得

```bash
git worktree list --porcelain
```

このコマンドは以下の形式で出力:
```
worktree /path/to/main
HEAD abc123...
branch refs/heads/main

worktree /path/to/feature
HEAD def456...
branch refs/heads/feature-branch
```

### 2. 各worktreeの情報収集

各worktreeについて以下の情報を収集:

#### a. パスとブランチ名
porcelain出力から抽出

#### b. 未コミット変更の有無
```bash
git -C <worktree-path> status --porcelain
```
出力があれば未コミット変更あり

#### c. ahead/behind情報
```bash
git -C <worktree-path> rev-list --left-right --count HEAD...@{upstream} 2>/dev/null
```
出力形式: `<ahead>\t<behind>`
upstreamが設定されていない場合はエラーになるので、その場合は「upstream未設定」と表示

#### d. stale（リモート削除済み）ブランチの検出
```bash
git fetch --prune --dry-run 2>&1
```
または、ブランチのupstreamがリモートに存在するか確認:
```bash
git -C <worktree-path> branch -vv
```
で `[origin/branch: gone]` となっているものを検出

### 3. 結果の整形表示

テーブル形式で表示:

```
Worktrees:
┌─────────────────────────────────┬────────────────┬──────────────┬─────────────┐
│ Path                            │ Branch         │ Status       │ Upstream    │
├─────────────────────────────────┼────────────────┼──────────────┼─────────────┤
│ /home/user/repo                 │ main           │ clean        │ ↑0 ↓2       │
│ /home/user/repo-feature         │ feature-auth   │ 3 changes    │ ↑2 ↓0       │
│ /home/user/repo-bugfix          │ bugfix-123     │ clean        │ [gone]      │
└─────────────────────────────────┴────────────────┴──────────────┴─────────────┘
```

または、シンプルなMarkdown形式:

```
## Worktrees

### /home/user/repo (main)
- Status: clean
- Upstream: 2 commits behind

### /home/user/repo-feature (feature-auth)
- Status: 3 uncommitted changes
- Upstream: 2 commits ahead

### /home/user/repo-bugfix (bugfix-123) ⚠️
- Status: clean
- Upstream: [gone] - リモートで削除済み
```

### 4. サマリー

最後に以下のサマリーを表示:
- 総worktree数
- 未コミット変更があるworktree数
- staleブランチのworktree数（あれば警告として強調）

## 注意事項

- detached HEADのworktreeも正しく表示すること
- bare repositoryのworktreeも考慮すること（通常は最初のエントリ）
- パスが長い場合は適切に省略表示
