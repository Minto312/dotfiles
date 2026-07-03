---
name: office-render
description: PowerPoint / Word / Excel ファイル (.pptx/.docx/.xlsx 等) を、SSH 接続した Windows 機 (lenovo) 上の本物の Microsoft Office を COM 操作してレンダリングし、PNG 画像 / PDF に変換する。変換後、Claude がその画像を Read して中身を目視確認できる。「このpptxを見せて」「スライドを画像化」「wordをレンダリング」「pptx/docx/xlsx をPNGに」「Officeファイルを表示」「プレゼンの中身を確認」などで起動。LibreOffice では崩れるフォント・ロゴ・グラデーションも忠実に再現される。
argument-hint: "<file.pptx|docx|xlsx ...> [--format png|pdf|both] [--out <dir>] [--width <px>]"
disable-model-invocation: false
allowed-tools: Bash, Read
---

# Office レンダリングスキル (office-render)

`.pptx` / `.docx` / `.xlsx`（および `.ppt/.doc/.xls/.pps/.rtf/.csv`）を **本物の Microsoft Office** でレンダリングして PNG / PDF に変換する。Claude 単体では中身が読めない Office バイナリを「目で見える形」にするためのスキル。

## いつ使うか

- ユーザーが Office ファイルの**見た目**を確認したい / Claude に見せたいとき
- 生成・編集した pptx/docx がデザイン通りか目視レビューしたいとき
- Office ファイルの内容を要約・説明するために中身を把握する必要があるとき

XML を直接パースするより、まずこのスキルで PNG 化して Read するほうが速く正確。

## 仕組み（重要）

このマシン (develop, LXC) には Office が無い。代わりに **`ssh lenovo` で到達できる Windows 機**の Office を使う:

1. 対象ファイルを `scp` で lenovo の一時作業ディレクトリへアップロード
2. PowerShell (`-EncodedCommand` で UTF-16LE base64 送信) で Office を COM 操作
   - **PowerPoint**: スライドを 1 枚ずつ PNG に `Export` ＋ 必要なら PDF (`SaveAs 32`)
   - **Word**: `ExportAsFixedFormat 17` で PDF 化 → PNG は develop 側で `pdftoppm` によりラスタライズ
   - **Excel**: 各シートを fit-to-width にして `ExportAsFixedFormat 0` で PDF 化 → 同上
3. 生成物を `scp` で develop に回収し、lenovo の作業ディレクトリを削除
4. 出力先パスを標準出力に表示（Claude はそれを `Read` する）

LibreOffice (develop にもある) より優先する理由は **忠実度**。実 Office は作者が見ているのと同一のフォント・グラデーション・ロゴ・レイアウトで描画する。

## 使い方

```bash
python3 ~/.claude/skills/office-render/scripts/render.py <ファイル> [オプション]
```

例:

```bash
# プレゼン → スライドごとの PNG（既定）
python3 ~/.claude/skills/office-render/scripts/render.py deck.pptx

# Word → PDF（既定）。PNG も欲しければ --format both
python3 ~/.claude/skills/office-render/scripts/render.py report.docx --format both

# 出力先を指定
python3 ~/.claude/skills/office-render/scripts/render.py sheet.xlsx --format png --out ./rendered
```

### オプション

| オプション | 意味 | 既定 |
|---|---|---|
| `--format png\|pdf\|both\|auto` | 出力形式 | `auto`（プレゼン→png / Word・Excel→pdf） |
| `--out <dir>` | ローカル出力先 | `/tmp/office-render/<basename>`（実行ごとに中身をクリア） |
| `--width <px>` | PNG の横幅 | `1600` |
| `--host <alias>` | Windows 機の ssh ホスト名 | `lenovo` |
| `--keep-remote` | lenovo 側の作業ディレクトリを消さない（デバッグ用） | — |

## 実行後にすること

スクリプトが出力先パス（`slide-001.png …` や `page-1.png`、`<name>.pdf`）を表示するので、**その PNG を `Read` して中身を確認する**。PDF も `Read` の `pages` 指定で読める。ユーザーに見せる場合は該当ファイルを提示する。

## 出力の命名

- PowerPoint: `slide-001.png`, `slide-002.png`, …（ゼロ埋め連番・スライド順）
- Word / Excel: `page-1.png`, `page-2.png`, …（PDF の各ページ）＋ `<basename>.pdf`

> 注意: 既定の出力先は basename のみで決まるため、`a.docx` と `a.xlsx` のように**拡張子違いで同名**だと上書きされる。両方残したいときは `--out` で分ける。

## 前提・トラブルシュート

- **`ssh lenovo` が通ること**が大前提。`echo %USERPROFILE%` から失敗する場合は Windows 機の電源・ネットワーク・SSH 設定を確認（勝手にリトライを続けない）。
- `--host` で別ホストを指定する場合、**その Windows 機の SSH 既定シェルが cmd** であること（`%USERPROFILE%` 展開・`mkdir`・`rmdir /s /q` を前提にしている）。既定シェルが PowerShell だと `%USERPROFILE%` が展開できず明示エラーで停止する。
- lenovo には Office (COM: PowerPoint/Word/Excel) がインストール済みであること。バージョンは 16.0 (Office 2016+) で確認済み。
- Word/Excel の PNG 化には develop 側の `pdftoppm`（poppler-utils）が必要。無ければ `--format pdf` を使う。
- COM は SSH 経由の非対話セッションでも動作する（PowerPoint は `Visible` を立てず `WithWindow:=$false` で開く）。初回起動は数十秒かかることがある。
- エラー時は PowerShell の例外メッセージを `RENDER_ERR …` として表示する。
