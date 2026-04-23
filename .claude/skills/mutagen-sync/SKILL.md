---
name: mutagen-sync
description: develop マシンと Windows クライアント間の Mutagen 同期セッションを追加・一覧・削除する。「Mutagen で同期」「sync を追加」「ファイルを Windows と同期」などで起動。
argument-hint: "[add|list|remove|pause|resume] [オプション]"
disable-model-invocation: false
allowed-tools: Bash, Read, Write, Edit, Glob
---

# Mutagen 同期セッション管理スキル

develop (このマシン) と Windows クライアント間の Mutagen 双方向同期セッションを管理する。セッションのホームは **Windows 側のデーモン** (Option A 構成)。Claude はコマンドを実行するのではなく、**ユーザーに Windows 側で実行してもらう正しいコマンドを生成・提示**し、`/home/karinto/workspace/machine/dev/sync-sessions.md` にレジストリとして記録する役目を負う。

レジストリは必ず上記の絶対パス (machine ワークスペース配下) に作成・更新すること。CWD 依存の相対パスで書かないこと。

## 前提

- develop 側: Mutagen CLI が `~/.local/bin/mutagen` にインストール済み、systemd user unit `mutagen-daemon.service` で常駐
- Windows 側: ユーザー自身で Mutagen CLI をインストール済み（Scoop 推奨: `scoop install mutagen`）
- Windows → develop への SSH 接続が鍵認証で通る状態（wezterm での接続と同じ流儀）
- 詳細は `dev/sync-mutagen.md` を参照

## サブコマンド

引数の第一要素でサブコマンドを決める。省略時は `add` として扱う。

### `add` — 新規セッション追加

必要な情報:

1. **セッション名** (`--name`): 英数字とハイフンのみ。プロジェクト名と揃えるのが基本 (例: `machine`, `bett-docs`)
2. **local path** (Windows 側の絶対パス): デフォルトは **`C:/Users/karinto/Documents/sync/<session-name>`**。ユーザーが明示的に別パスを指定した場合のみそれを使う (例 `D:/workspace/foo`)
3. **remote path** (develop 側の絶対パス): 例 `/home/karinto/workspace/machine`
4. **同期モード**: デフォルトは `two-way-safe`。片方向にしたい場合は `one-way-safe` 等
5. **追加無視パターン** (任意): `.gitignore` はデフォルトで尊重される (`--ignore-vcs`)

#### 手順

1. ユーザーから 1〜3 を聞き取る (既に引数で与えられていればそれを使う)。local path が未指定ならデフォルト `C:/Users/karinto/Documents/sync/<session-name>` を採用し、その旨を明示してユーザーの確認を取る
2. remote path が develop 側に実在するか `ls -ld <remote_path>` で確認。存在しなければ作成するか確認を取る
3. `/home/karinto/workspace/machine/dev/sync-sessions.md` を読み、同名セッションが既にないか確認 (ファイルが無ければ新規作成)
4. 下記テンプレートに値を埋めてコマンドを生成

    ```powershell
    mutagen sync create `
      --name=<SESSION_NAME> `
      --mode=<MODE> `
      --ignore-vcs `
      --symlink-mode=portable `
      '<WINDOWS_PATH>' `
      'karinto@develop:<REMOTE_PATH>'
    ```

    cmd.exe の場合はバッククォートの代わりに `^` を使う旨を併記する。

5. `/home/karinto/workspace/machine/dev/sync-sessions.md` にエントリを追記 (下記フォーマット)
6. ユーザーに「このコマンドを Windows の PowerShell で実行してください」と明示して提示
7. 実行後、Windows 側で `mutagen sync list` を実行して Status が `Watching` になっていることを確認するよう案内

#### レジストリ形式 (`/home/karinto/workspace/machine/dev/sync-sessions.md`)

各セッションは下記ブロックで記録する:

```markdown
## <session-name>

- **作成日**: YYYY-MM-DD
- **Local (Windows)**: `C:/path/to/dir`
- **Remote (develop)**: `/home/karinto/path/to/dir`
- **Mode**: two-way-safe
- **用途**: (このセッションで何をしたいか。pptx 編集 / dev サーバ用など)
- **備考**: (特殊な ignore ルールや注意点があれば)
```

### `list` — セッション一覧

`/home/karinto/workspace/machine/dev/sync-sessions.md` を読んで登録されているセッション名と用途を一覧表示する。

併せて、ユーザーに Windows 側で `mutagen sync list` を実行するよう案内し、実際のステータスと照合させる (レジストリは Claude が管理するメタ情報で、真のソースは Windows 側デーモン)。

### `remove` — セッション削除

1. `/home/karinto/workspace/machine/dev/sync-sessions.md` から該当エントリを探す
2. Windows で実行するコマンドを提示:

    ```powershell
    mutagen sync terminate <session-name>
    ```

3. ユーザーの確認後、`/home/karinto/workspace/machine/dev/sync-sessions.md` から該当ブロックを削除

### `pause` / `resume` — 一時停止・再開

該当セッション名に対して下記を提示するだけ:

```powershell
mutagen sync pause <session-name>
mutagen sync resume <session-name>
```

レジストリは変更しない。

## 注意事項

- **Claude は Windows 側でコマンドを実行できない**。全ての `mutagen sync *` 操作はユーザーに実行してもらう
- **Windows 側のデフォルト置き場は `C:/Users/karinto/Documents/sync/`**。セッション名をそのままサブディレクトリ名にする。初回作成時にディレクトリが無ければ Windows 側で `New-Item -ItemType Directory -Path 'C:/Users/karinto/Documents/sync/<session-name>'` を実行するよう案内する
- **Windows のパスは forward slash 推奨** (Mutagen はどちらも受け付けるが、PowerShell でのエスケープが楽)
- セッションを作る前に、**remote path 側に既に中身がある場合は初回同期で競合しうる**ので、空ディレクトリから始めるか、片方を完全に正とする `one-way-safe` で一度同期してから `two-way-safe` に切り替える運用を案内する
- `.gitignore` は `--ignore-vcs` で尊重されるが、`node_modules/` など巨大ディレクトリが無視対象に入っているかは同期前に確認する
- Windows 側でコマンド実行後に `Error: unable to locate agent bundle` 等が出た場合は、Windows の Mutagen CLI とバージョンがずれている可能性あり。develop 側は `mutagen version` = 0.18.1
