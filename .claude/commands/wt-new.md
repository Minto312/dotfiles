# Worktree作成スキル

引数 `$ARGUMENTS` で指定されたブランチ名でgit worktreeを作成する。

## 前提条件

- 現在のディレクトリがgitリポジトリ内であること
- 引数にブランチ名が指定されていること

## 手順

### 1. 引数の検証

`$ARGUMENTS` が空の場合はエラーメッセージを表示して終了:
「ブランチ名を指定してください。例: /wt-new feature-auth」

### 2. worktreeパスの決定

パス形式: `../<ブランチ名>`

例: ブランチが `feature-auth` の場合 → `../feature-auth`

注意: ブランチ名に `/` が含まれる場合（例: `feature/auth`）は、`/` を `-` に置換する
例: `feature/auth` → `../feature-auth`

### 3. 既存worktreeの確認

```bash
git worktree list
```
で同じパスのworktreeが既に存在しないか確認。
存在する場合は「既にworktreeが存在します: <パス>」と表示して終了。

### 4. ブランチの存在確認と作成

ローカルブランチの存在確認:
```bash
git show-ref --verify --quiet refs/heads/<ブランチ名>
```

リモートブランチの存在確認:
```bash
git ls-remote --heads origin <ブランチ名>
```

**分岐**:
- ローカルに存在 → そのブランチでworktree作成
- リモートにのみ存在 → リモート追跡ブランチとしてworktree作成
- どちらにも存在しない → 新規ブランチとしてworktree作成（現在のHEADから分岐）

### 5. worktreeの作成

状況に応じて適切なコマンドを実行:

**ローカルブランチが存在する場合**:
```bash
git worktree add <パス> <ブランチ名>
```

**リモートにのみ存在する場合**:
```bash
git worktree add <パス> -b <ブランチ名> origin/<ブランチ名>
```

**新規ブランチの場合**:
```bash
git worktree add -b <ブランチ名> <パス>
```

### 6. 依存関係のインストール

作成したworktreeディレクトリに移動し、パッケージマネージャの設定ファイルを確認:

- `package-lock.json` が存在 → `npm ci`
- `package.json` のみ存在 → `npm install`
- `yarn.lock` が存在 → `yarn install`
- `pnpm-lock.yaml` が存在 → `pnpm install`
- `Cargo.toml` が存在 → `cargo build`（オプション、重い場合はスキップ可）

### 7. 完了メッセージ

以下の情報を表示:
- 作成したworktreeのパス
- ブランチ名
- 依存関係インストールの結果
- 移動コマンドの案内: `cd <パス>`

## エラーハンドリング

- gitリポジトリ外で実行された場合: 適切なエラーメッセージを表示
- worktree作成に失敗した場合: gitのエラーメッセージを表示
- 依存関係インストールに失敗した場合: 警告を表示するが、worktree自体は作成済みとして扱う
