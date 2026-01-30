# Worktree一括同期スキル

全worktreeでリモートとの同期を行い、各worktreeのupstream状況をレポートする。

## 前提条件

- 現在のディレクトリがgitリポジトリ内であること

## 手順

### 1. worktree一覧の取得

```bash
git worktree list --porcelain
```

### 2. メインリポジトリでfetch実行

まず、メインリポジトリでfetchを実行（全worktreeで共有されるため一度でOK）:

```bash
git fetch --all --prune
```

これにより:
- 全リモートから最新情報を取得
- リモートで削除されたブランチの参照を削除

### 3. 各worktreeの状況確認

各worktreeについて以下の情報を収集:

#### a. ブランチ名とHEAD
```bash
git -C <worktree-path> rev-parse --abbrev-ref HEAD
```

#### b. upstream設定の確認
```bash
git -C <worktree-path> rev-parse --abbrev-ref @{upstream} 2>/dev/null
```

#### c. ahead/behind情報
```bash
git -C <worktree-path> rev-list --left-right --count HEAD...@{upstream} 2>/dev/null
```

#### d. gone（リモート削除済み）の検出
```bash
git -C <worktree-path> branch -vv | grep '\[.*: gone\]'
```

#### e. 未コミット変更の有無
```bash
git -C <worktree-path> status --porcelain
```

### 4. 結果のレポート

各worktreeの状況を整理して表示:

```
## Sync Report

Fetched from all remotes.

### Worktree Status

| Path | Branch | Ahead | Behind | Local Changes | Notes |
|------|--------|-------|--------|---------------|-------|
| /home/user/repo | main | 0 | 0 | clean | ✓ |
| /home/user/repo-feature | feature-auth | 2 | 3 | 5 files | needs rebase |
| /home/user/repo-old | old-feature | - | - | clean | ⚠️ gone |

### Summary

- Total worktrees: 3
- Up to date: 1
- Behind upstream: 1 (consider pulling)
- Ahead of upstream: 1 (consider pushing)
- Stale (gone): 1 (consider cleanup with /wt-clean)
- With local changes: 1
```

### 5. アクション提案

状況に応じて次のアクションを提案:

#### behindがあるworktree
```
以下のworktreeはupstreamより遅れています:
- /home/user/repo-feature (3 commits behind)

`git -C <path> pull --rebase` で更新できます。
```

#### aheadがあるworktree
```
以下のworktreeはpush待ちのコミットがあります:
- /home/user/repo-feature (2 commits ahead)

`git -C <path> push` でpushできます。
```

#### goneブランチ
```
以下のworktreeのブランチはリモートで削除されています:
- /home/user/repo-old

`/wt-clean` でクリーンアップできます。
```

#### 未コミット変更
```
以下のworktreeに未コミットの変更があります:
- /home/user/repo-feature (5 files)
```

### 6. オプション: 自動pull/push

ユーザーが希望すれば、以下の操作を提案:

AskUserQuestionツールで確認:
- 「遅れているworktreeをすべてpull」
- 「pushできるworktreeをすべてpush」
- 「詳細を確認して個別に操作」
- 「何もしない」

**注意**: 自動操作は未コミット変更がないworktreeのみ対象。
コンフリクトが発生した場合は処理を中断し、ユーザーに通知。

## エラーハンドリング

- fetch失敗時: ネットワークエラーの可能性を示唆し、オフラインでも利用可能な情報（ローカルの状態）のみ表示
- 個別worktreeへのアクセス失敗: 警告を表示し、他のworktreeの処理は続行
- upstreamが設定されていないブランチ: 「upstream未設定」として表示
