---
name: export-gdocs
description: セッション中に作成したレポートをGoogle Docsに直接書き出す。「Google Docsに書き出し」「レポートをアップロード」「gdocsにエクスポート」などで起動。
argument-hint: "[Google DriveフォルダURL or フォルダID (省略可)]"
disable-model-invocation: false
allowed-tools: Bash, Read, Glob, Grep, Write, Edit
---

# Google Docsエクスポートスキル

セッション中に作成したレポートを Markdown として書き出し、`pandoc` で docx に変換した上で Google Drive にアップロードして Google Docs 化する。

## 前提ツール

- `pandoc` — Markdown → docx 変換 (`apt install pandoc`)
- `python-docx` — pandoc 出力 docx の表装飾後処理 (`uv pip install python-docx` を専用 venv に)
- `gws` — Google Workspace CLI (`npm install -g @googleworkspace/cli`)

## なぜこの方式か

以前は `gws docs documents batchUpdate` で Docs API を直接叩いて構造化挿入していたが、

- 見出し・箇条書き・テーブル・コードブロック等を都度 `insertText` + `updateParagraphStyle` + `createParagraphBullets` … で組み立てるためリクエストが肥大化し、インデックス計算ミスが起きやすい
- マークダウン記号 (`#`, `|`, `---`, `**`, `` ` ``) を除去しつつ等価なスタイルに変換する処理を毎回手書きする必要があった

`md → pandoc → docx → Drive upload (convert=true)` に統一することで、変換ロジックは pandoc に丸投げでき、スキル側は「Markdown 本文を作る」「アップロードする」だけに専念できる。

## 手順

### 1. アップロード先フォルダの決定

引数として Google Drive のフォルダ URL またはフォルダ ID が渡された場合はそれを使う。

- URL の場合 (`https://drive.google.com/drive/folders/XXXX`): `XXXX` の部分をフォルダ ID として抽出する
- ID の場合: そのまま使う
- 引数なしの場合: デフォルトのフォルダ ID `1ljT5Nk9l06nDskmCrMv3szn0Db3NiEUS` を使う

### 2. エクスポート対象の確認

セッション中の会話を振り返り、レポートとして書き出す内容をユーザに提示して確認を取る。
ドキュメント名もここで決める (プロジェクトの CLAUDE.md に記載があればそれに従い、なければユーザに聞く)。

### 3. Markdown 本文の作成

レポート本文を Markdown として一時ファイルに書き出す。

```bash
TMPDIR=$(mktemp -d)
MD_PATH="$TMPDIR/report.md"
DOCX_PATH="$TMPDIR/report.docx"
```

Markdown の書き方ガイド:

- タイトルは `# タイトル` で 1 行目に置く (pandoc がドキュメントタイトルとして扱う)
- 見出しは `##` (大), `###` (中), `####` (小) を使う
- 箇条書きは `- ` で始める。ネストはインデント 2 スペース
- テーブルは GFM 形式 (`| 列1 | 列2 |` + 区切り行) で書く
- コードは `` ``` `` のフェンス、インラインコードは `` ` ``
- 強調は `**bold**` / `*italic*`
- 区切り線 `---` は不要 (見出しで区切られる)

**重要**: 以前のように記号を除去する必要はない。pandoc が docx ネイティブのスタイル (Heading 1/2/3, List, Table, Code) に変換する。

### 4. pandoc で docx に変換

```bash
pandoc "$MD_PATH" -o "$DOCX_PATH" \
  --from gfm \
  --to docx \
  --standalone
```

オプションの意図:

- `--from gfm` — GitHub Flavored Markdown として解釈 (テーブル・タスクリスト対応)
- `--to docx` — Word docx 形式で出力
- `--standalone` — 単独で開ける完全な docx を生成

スタイルを調整したい場合は `--reference-doc <ref.docx>` で参照テンプレートを指定できる (任意)。

### 4.5. 表装飾の後処理（必須）

pandoc 既定の docx は表に罫線がなく、A4 縦の既定余白も広いため、日本語 + 多列テーブルが極端に読みづらい。スキル同梱の `style_tables.py` で後処理する。

```bash
# python-docx が入った venv を用意（初回のみ）
if [ ! -d /tmp/docs-venv ]; then
  uv venv /tmp/docs-venv
  /tmp/docs-venv/bin/python -m pip install --quiet python-docx 2>/dev/null \
    || (cd /tmp && source docs-venv/bin/activate && uv pip install python-docx)
fi

# 装飾を適用（入力 → 装飾後の出力）
DOCX_STYLED="$TMPDIR/report_styled.docx"
/tmp/docs-venv/bin/python "$CLAUDE_SKILL_DIR/style_tables.py" "$DOCX_PATH" "$DOCX_STYLED"
DOCX_PATH="$DOCX_STYLED"
```

スクリプトの内容（`style_tables.py`、スキル同梱）:

- 全テーブルの全セルに単線（黒・幅 0.5pt）罫線を追加
- 1 行目（ヘッダ）に薄グレー (#DDDDDD) 背景 + 太字を適用
- セル内余白を上下 40 twips / 左右 80 twips に詰める
- テーブル全体を中央寄せ
- 本文段落フォントを 10pt、テーブル内フォントを 9pt に圧縮
- A4 縦のまま左右余白 15mm / 上下余白 18mm に縮小（既定 25mm から削減し横幅 +20mm 確保）

意図的にやらないこと:

- ページを横向き / A3 にしない（A4 縦印刷の前提を維持）
- 列幅の個別指定をしない（autofit のまま、コンテンツに合わせて Docs 側に任せる）
- 見出しスタイルは触らない（pandoc が付けた Heading 1/2/3 を尊重）

挙動を変えたい場合は `style_tables.py` のパラメータ（罫線色 `color`、ヘッダ背景 `fill_hex`、余白 `Mm()` 値、フォントサイズ `Pt()` 値）を直接編集する。

### 5. Drive にアップロードして Google Docs 化

`gws drive files create` の `--upload` で docx 実体を送り、`--json` のメタデータで `mimeType` を `application/vnd.google-apps.document` に指定する。これにより Drive は docx → Google Docs に自動変換した上で保存する。`parents` で配置先フォルダも同時に指定する。

```bash
gws drive files create \
  --upload "$DOCX_PATH" \
  --upload-content-type 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' \
  --json "$(cat <<EOF
{
  "name": "<ドキュメント名>",
  "mimeType": "application/vnd.google-apps.document",
  "parents": ["<フォルダID>"]
}
EOF
)"
```

レスポンス JSON の `id` フィールドが Google Docs のドキュメント ID になる。

注意:

- `--upload-content-type` は docx の正式 MIME (`application/vnd.openxmlformats-officedocument.wordprocessingml.document`)。省略すると拡張子から推定されるが、明示する方が確実。
- メタデータの `mimeType` を変換先 (`application/vnd.google-apps.document`) にする点が肝。これを書かないと docx ファイルのまま Drive に置かれる。
- `parents` を最初から指定するので、旧手順のような「作成後に Drive で移動する」追加コールは不要。
- `gws drive files create` の `--upload` は **カレントディレクトリ配下のパスのみ**を受け取る制約がある。`$TMPDIR` が cwd 外の場合は事前に cwd 直下にコピーしてからアップロードし、終了時に削除する（例: `cp "$DOCX_PATH" .report_upload.docx` → upload → `rm -f .report_upload.docx`）。

### 6. 完了報告

ドキュメントの URL を表示して完了を報告する。

```
https://docs.google.com/document/d/<DOC_ID>/edit
```

一時ファイル (`$TMPDIR`) は後片付けする (`rm -rf "$TMPDIR"`)。
