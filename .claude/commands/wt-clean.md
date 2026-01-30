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

#### b. マージ済みブランチの検出

メインブランチ（main または master）にマージ済みかチェック:
```bash
git branch --merged main
```
または
```bash
git branch --merged master
```

**注意**: メインブランチ自体のworktreeは削除候補にしない

### 4. 削除候補の表示と確認

削除候補がない場合:
「クリーンアップ対象のworktreeはありません。」と表示して終了

削除候補がある場合、一覧を表示:

```
以下のworktreeが削除候補です:

1. /home/user/repo-feature (feature-old)
   理由: リモートで削除済み [gone]

2. /home/user/repo-bugfix (bugfix-123)
   理由: mainにマージ済み

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
