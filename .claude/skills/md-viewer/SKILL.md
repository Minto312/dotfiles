---
name: md-viewer
description: カレントディレクトリの Markdown ファイルをブラウザで閲覧するための簡易 HTTP ビューアを起動・停止・状態確認する。「MDビューア起動」「ビューア立ち上げ」「md読みたい」「viewer停止」などで起動。
argument-hint: "[start|stop|status|restart] [--port <PORT>]"
disable-model-invocation: false
allowed-tools: Bash, Read, Write
---

# md-viewer — Markdown ブラウザビューア管理

カレントディレクトリ直下の `*.md` を一覧表示し、`marked.js` + `github-markdown-css` (CDN) で GitHub 風レンダリングするローカル HTTP サーバを管理する。

## 前提

- ホスト: `develop-1`（既定、Linux）。バインドは `0.0.0.0` のため LAN から閲覧可能。R18 等の機密原稿を扱う場合は SSH ポートフォワード運用に切り替えるか、`viewer.py` の bind を `127.0.0.1` に変更することを検討する。
- 既定ポート: **9876**。占有時はユーザーに別ポートを確認するか、空いているものを提示する。
- ビューア本体: `viewer.py`（作業ディレクトリ直下に配置されているはず）。無い場合は git からの復元 or ユーザー確認を優先し、勝手に再生成しない。
- 依存: Python 3.10 以上（標準ライブラリのみ）。レンダリングは `marked.js` (12.x) と `github-markdown-css` の CDN 配信。**信頼できる作者の Markdown のみ**を表示する前提（`marked` 12.x は sanitize オプションが廃止されているため、悪意ある入力では XSS の余地あり）。

## サブコマンド

引数を解釈し、無指定なら `status` 相当を返してから次のアクションをユーザーに尋ねる。

### `start` — 起動

1. 既に起動中なら（`status` を実行して確認）二重起動はしない。URL を案内して終了。
2. 作業ディレクトリに `viewer.py` が無ければ作成する。
3. 既定ポート `9876` で `python3 viewer.py 9876` を**バックグラウンド**で起動する（Bash の `run_in_background: true`）。
4. 1 秒待ってから `curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:<PORT>/` でヘルスチェック。`200` を確認すること。
5. 起動メッセージは「`http://develop-1:<PORT>/` で開けます」を中心に簡潔に。

ポート占有 (`Address already in use`) が出たら、`9877`, `9878` ... と次の空きを試すか、ユーザーに希望ポートを尋ねる。

### `stop` — 停止

1. `pgrep -f "python3 viewer.py"` で PID を取得。
2. 該当があれば `kill <PID>`。プロセスが残っていれば `kill -9 <PID>` まで段階的に。
3. 停止できたことを `pgrep -f` で再確認。
4. 報告は 1 行（「停止しました」程度）。

### `status` — 状態確認

1. `pgrep -af "python3 viewer.py"` で起動状態とポートを取得（コマンドラインからポート番号を抽出）。
2. 起動中なら URL（`http://develop-1:<PORT>/`）と PID を返す。停止中ならその旨返す。

### `restart` — 再起動

`stop` → `start` の順に実行する。`viewer.py` を更新したあと反映したい場合に使う。

## 設計上の注意

- **作業ディレクトリ外への path traversal は許可しない**。`viewer.py` の `_resolve` は cwd 配下のみを返す実装にすること。
- レンダリングはクライアントサイド（`marked.js`）。HTML エスケープは `marked` に任せ、サーバ側は raw Markdown を `text/plain; charset=utf-8` で返す。
- ログは標準エラーへ。アクセスログを抑制したい場合は `log_message` を no-op に。
- ファイルの追加削除はインデックス再描画で反映される（再起動不要）。
- `*.md` 以外（画像など）は対象外。必要になったら拡張する。

## viewer.py の復元

`viewer.py` が紛失している場合、独力で再生成しない。以下を順に試す:

1. `git log --all --diff-filter=A -- viewer.py` で過去コミットを探し、見つかれば `git show <sha>:viewer.py > viewer.py` で復元。
2. 別ワークツリー／バックアップから持ってくる。
3. どちらも不可の場合のみ、ユーザーに「再生成して良いか」を確認してから新規実装する（過去のスキル定義に縛られず、現状の要件で書き直す）。

## 使い分けの目安

- 「MD見たい」「ビューア欲しい」→ `start`
- 「ポート空けて」「サーバ落として」→ `stop`
- 「動いてる？」「URL教えて」→ `status`
- 「viewer.py 直したから反映して」→ `restart`

## 報告フォーマット

起動成功時の標準形式:

```
http://develop-1:9876/ で開けます（PID: 12345）
```

失敗時はエラー出力（`viewer.py` のスタックトレース）を貼った上で原因と対処を 1〜2 行で添える。
