---
name: gws
description: Google Workspace CLI (gws) で Gmail・Drive・Docs・Sheets・Calendar などを操作する。「メールを送って」「カレンダーに予定追加」「スプレッドシートを読んで」「Drive からダウンロード」などで起動。
disable-model-invocation: false
allowed-tools: Bash, Read, Write
---

# gws — Google Workspace CLI の使い方

gws (`@googleworkspace/cli`) は Google Workspace の18サービス (Gmail, Drive, Docs, Sheets, Calendar, Slides, Tasks, Chat, Meet, Forms 等) を単一 CLI で操作するツール。

## 基本構文

```
gws <service> <resource> [sub-resource] <method> [flags]
```

主要フラグ:

- `--params '<JSON>'` — URL / クエリパラメータ（例: `{"fileId": "abc"}`, `{"userId": "me"}`）
- `--json '<JSON>'` — リクエストボディ（POST / PATCH / PUT 時）
- `--upload <PATH>` — アップロードするローカルファイル
- `-o <PATH>` — バイナリレスポンスの保存先（**カレントディレクトリ配下のみ**、絶対パス不可）
- `--format <FMT>` — 出力形式: `json` (デフォルト) / `table` / `yaml` / `csv`
- `--page-all` — 自動ページング（NDJSON 出力）
- `--dry-run` — 実行せずに検証のみ

## 認証

初回は `gws auth login` をターミナルで実行（ブラウザが開く OAuth フロー）。認証情報は OS のキーリング（develop マシンでは Secret Service）に保存される。

## サービスと代表操作

### Gmail
```bash
# 送信（ヘルパー）
gws gmail +send --to foo@example.com --subject '件名' --body '本文'

# 未読サマリー
gws gmail +triage

# 検索
gws gmail users messages list --params '{"userId": "me", "q": "from:foo@example.com"}'

# 返信（スレッドIDを自動処理）
gws gmail +reply --message-id <ID> --body '返信本文'
```

### Drive
```bash
# アップロード（メタデータ自動）
gws drive +upload ./file.pdf --parent <FOLDER_ID> --name 'ファイル名'

# ファイル検索
gws drive files list --params '{"q": "name contains \"report\"", "pageSize": 10}'

# ダウンロード（バイナリ）
gws drive files get --params '{"fileId": "<ID>", "alt": "media"}' -o local.pdf

# フォルダへの移動
gws drive files update --params '{"fileId": "<ID>", "addParents": "<FOLDER>", "removeParents": "root"}' --json '{}'

# 削除
gws drive files delete --params '{"fileId": "<ID>"}'

# 共有権限追加
gws drive permissions create --params '{"fileId": "<ID>"}' --json '{"role": "reader", "type": "anyone"}'
```

### Docs
```bash
# 作成
gws docs documents create --json '{"title": "ドキュメント名"}'

# 末尾に追記（プレーンテキスト）
gws docs +write --document <DOC_ID> --text '追記する本文'

# 構造化編集（見出し・段落・箇条書き等）は batchUpdate
# → 詳細は export-gdocs スキルの手順4を参照
```

### Sheets
```bash
# 値の読み取り
gws sheets +read --spreadsheet <ID> --range 'Sheet1!A1:C10'

# 行の追記
gws sheets +append --spreadsheet <ID> --range 'Sheet1!A:C' --values '[["a","b","c"]]'

# スプレッドシート作成
gws sheets spreadsheets create --json '{"properties": {"title": "シート名"}}'
```

### Calendar
```bash
# 直近の予定
gws calendar +agenda

# イベント作成（ヘルパー）
gws calendar +insert --calendar primary --summary '会議' --start '2026-04-20T10:00:00+09:00' --end '2026-04-20T11:00:00+09:00'

# イベント一覧
gws calendar events list --params '{"calendarId": "primary", "timeMin": "2026-04-17T00:00:00Z", "maxResults": 20}'

# 空き時間照会
gws calendar freebusy query --json '{"timeMin": "...", "timeMax": "...", "items": [{"id": "primary"}]}'
```

### Chat
```bash
gws chat +send --space <SPACE_ID> --text 'メッセージ'
gws chat spaces list
```

### Tasks
```bash
gws tasks tasklists list
gws tasks tasks insert --params '{"tasklist": "@default"}' --json '{"title": "新タスク"}'
```

## クロスサービスワークフロー

複数サービスを組み合わせた便利コマンド:

```bash
gws workflow +standup-report     # 今日の会議 + 未完了タスク
gws workflow +meeting-prep       # 次の会議の準備情報
gws workflow +email-to-task      # Gmail → Tasks 変換
gws workflow +weekly-digest      # 週次サマリー
gws workflow +file-announce      # Drive ファイルを Chat に通知
```

## よく使うパターン

### スキーマ確認

API の正確なパラメータを調べたいとき:
```bash
gws schema drive.files.list
gws schema docs.documents.batchUpdate --resolve-refs
```

### JSONレスポンスのパース

gws の出力は先頭に `Using keyring backend: keyring` などの stderr 行が混ざる場合があるため、パース時は `2>/dev/null` を付ける:
```bash
gws drive files list --params '{"pageSize": 5}' 2>/dev/null | python3 -c "import sys, json; d=json.load(sys.stdin); print([f['name'] for f in d['files']])"
```

### `userId: "me"` パターン

Gmail / People など多くのサービスで、認証ユーザー自身を指すには `"userId": "me"` を使う。

### ページング

大量データは `--page-all` で自動ページング（NDJSON）:
```bash
gws gmail users messages list --params '{"userId": "me"}' --page-all --page-limit 5
```

## ハマりどころ

- **`-o` の絶対パス不可**: `-o /tmp/out.json` は弾かれる。カレントディレクトリからの相対パスで指定する
- **stderr の汚染**: `Using keyring backend: keyring` が stderr に出るのでパイプ処理時は `2>/dev/null` を推奨
- **delete 系の奇妙な出力**: `files delete` などが `{"saved_file": "download.html", ...}` と返してくることがある（空レスポンスをダウンロード扱いする挙動）が、実際は成功している
- **pre-v1.0**: 破壊的変更の可能性あり。コマンドが動かなくなったら `gws --version` でバージョンを確認

## 関連スキル

- `export-gdocs` — セッション中のレポートを Google Docs に書き出す（gws を使用）

## リファレンス

- 公式リポジトリ: https://github.com/googleworkspace/cli
- `gws --help` でサービス一覧
- `gws <service> --help` で各サービスのリソース一覧
- `gws <service> <resource> --help` で各メソッド一覧
