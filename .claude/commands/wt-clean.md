# Worktreeクリーンアップスキル

マージ済みまたはリモートで削除済みのブランチに関連するworktreeを検出し、ユーザー確認後に削除する。

## 前提条件

- 現在のディレクトリがgitリポジトリ内であること

## 手順

### 1. リモート情報の更新

```bash
git fetch --prune
```

### 2. worktree一覧の取得

```bash
git worktree list --porcelain
```

### 3. 削除候補の検出

各worktreeについて以下をチェック:

#### a. gone（リモート削除済み）ブランチの検出

```bash
git -C <worktree-path> branch -vv
```
出力に `[origin/<branch>: gone]` が含まれるものを検出

#### b. マージ済みブランチの検出（スカッシュマージ対応）

以下の2つの方法で判定し、**いずれかが該当すればマージ済み**とする。

**方法1: `git merge-tree` による差分チェック**

```bash
ancestor=$(git merge-base develop <ブランチ名>)
result=$(git merge-tree $ancestor develop <ブランチ名>)
```

- `result` が空 → マージ済み

**方法2: GitHub PRのマージ状態チェック**

`gh` CLIが利用可能な場合、対応するPRがマージ済みかを確認する:

```bash
gh pr list --state merged --head <ブランチ名> --json number,title,mergedAt
```

- 結果が空でない（マージ済みPRが存在する） → マージ済み

方法1は、ブランチの変更がdevelopに含まれているかをローカルで判定する。ただしスカッシュマージ後にdevelop側に追加コミットがあると差分ありと誤判定する場合がある。方法2はGitHub上の実際のマージ状態を確認するため、より正確。

**注意**: `develop`、`main` 自体のworktreeは削除候補にしない

### 4. 削除候補の表示と確認

削除候補がない場合:
「クリーンアップ対象のworktreeはありません。」と表示して終了

削除候補がある場合、一覧を表示:

```
以下のworktreeが削除候補です:

1. /home/user/repo-feature (feature-old)
   理由: リモートで削除済み [gone]

2. /home/user/repo-bugfix (bugfix-123)
   理由: developに取り込み済み（スカッシュマージ含む）

削除を実行しますか？
```

AskUserQuestionツールを使用してユーザーに確認:
- 「すべて削除」
- 「個別に選択」
- 「キャンセル」

### 5. 未コミット変更の確認

削除対象のworktreeに未コミット変更がある場合は警告:

```
⚠️ 警告: /home/user/repo-feature には未コミットの変更があります。
本当に削除しますか？
```

未コミット変更がある場合は、そのworktreeについて個別に確認を求める。

### 6. worktreeの削除

確認後、以下のコマンドで削除:

```bash
git worktree remove <path>
```

強制削除が必要な場合（未コミット変更があってもユーザーが確認した場合）:
```bash
git worktree remove --force <path>
```

### 7. ブランチの削除（オプション）

worktree削除後、対応するローカルブランチも削除するか確認:

```
ローカルブランチも削除しますか？
- feature-old
- bugfix-123
```

確認後:
```bash
git branch -d <branch-name>
```

マージされていないブランチの場合は `-D` が必要だが、その場合は再度確認。

### 8. prune実行

最後に孤立したworktree参照をクリーンアップ:

```bash
git worktree prune
```

### 9. 完了メッセージ

削除されたworktreeとブランチの一覧を表示:

```
クリーンアップ完了:
- 削除したworktree: 2
- 削除したブランチ: 2

残りのworktree: 3
```

## エラーハンドリング

- worktree削除に失敗した場合: エラーメッセージを表示し、他の削除処理は続行
- ブランチ削除に失敗した場合: 警告を表示するが、処理は続行
- メインworktree（bare repository）の削除を試みた場合: エラーとして拒否
