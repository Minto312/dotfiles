---
name: export-gdocs
description: セッション中に作成したレポートをGoogle Docsに直接書き出す。「Google Docsに書き出し」「レポートをアップロード」「gdocsにエクスポート」などで起動。
argument-hint: "[Google DriveフォルダURL or フォルダID (省略可)]"
disable-model-invocation: false
allowed-tools: Bash, Read, Glob, Grep, Write, Edit
---

# Google Docsエクスポートスキル

セッション中に作成したレポートを Google Docs に直接書き出す。

## 前提ツール

- `gws` — Google Workspace CLI (`npm install -g @googleworkspace/cli`)

## 手順

### 1. アップロード先フォルダの決定

引数としてGoogle DriveのフォルダURLまたはフォルダIDが渡された場合はそれを使う。

- URLの場合（`https://drive.google.com/drive/folders/XXXX`）: XXXXの部分をフォルダIDとして抽出する
- IDの場合: そのまま使う
- 引数なしの場合: デフォルトのフォルダID `1ljT5Nk9l06nDskmCrMv3szn0Db3NiEUS` を使う

### 2. エクスポート対象の確認

セッション中の会話を振り返り、レポートとして書き出す内容をユーザに提示して確認を取る。
ドキュメント名もここで決める（プロジェクトのCLAUDE.mdに記載があればそれに従い、なければユーザに聞く）。

### 3. Google Docs の作成

```bash
gws docs documents create --json '{"title": "<ドキュメント名>"}'
```

レスポンスから `documentId` を取得する。

### 4. レポート内容の書き込み

`gws docs documents batchUpdate` で構造化されたコンテンツを書き込む。

```bash
gws docs documents batchUpdate --params '{"documentId": "<DOC_ID>"}' --json '<リクエストJSON>'
```

リクエストJSONの構成ルール:

1. **まず `insertText` でテキストを一括挿入する**（index: 1 から）
2. **次に `updateParagraphStyle` で見出しスタイルを適用する**
   - `TITLE`, `SUBTITLE`, `HEADING_1`, `HEADING_2`, `HEADING_3` 等を使う
   - `fields` には `"namedStyleType"` を指定
3. **箇条書きは `createParagraphBullets` で適用する**
   - `bulletPreset`: `"BULLET_DISC_CIRCLE_SQUARE"`
4. **太字・斜体が必要な場合は `updateTextStyle` を使う**
   - `fields` に `"bold"` や `"italic"` を指定

注意:
- テキスト挿入後のインデックスを正確に計算すること（日本語は1文字=1インデックス、改行も1）
- リクエストが大きい場合は複数回の batchUpdate に分割する（目安: 1リクエストあたり 150 操作程度）
- `--json` は文字列引数なので、大きな JSON は一時ファイルに書き出して `"$(cat /tmp/req.json)"` で展開する

### 4.5. Google Docs スタイル最適化（重要）

**マークダウン記法はそのまま挿入しない。** `#` 見出し、`|` テーブル、`---` 区切り線、`` ``` `` コードフェンス、`` ` `` インラインコード、`**bold**` などの記号文字は Docs では装飾されず、生の記号として表示されて見栄えが悪い。

ソース（markdownメモ等）を流し込む際は、以下のように Docs ネイティブの機能へ**必ず変換する**:

| マークダウン | Google Docs での表現 |
|---|---|
| `# 見出し` | テキストは `見出し` のみ。段落に `HEADING_1` スタイルを適用 |
| `## 見出し` / `### 見出し` | 同上（`HEADING_2` / `HEADING_3`） |
| タイトル | `TITLE` スタイル（`# ` より優先して使う） |
| 副題・メタ情報 | `SUBTITLE` スタイル |
| `---` 区切り線 | 削除。見出しスタイルで視覚的に十分区切られる |
| `|...|...|` テーブル | `insertTable` で本物の表を作る。小規模なら等幅フォントのタブ整形でも可 |
| `` ```code``` `` / `` `inline` `` | 記号は除去し、該当範囲に `updateTextStyle` で等幅フォント（`Roboto Mono` 9pt）＋薄い背景色（rgb 0.96, 0.96, 0.96）を適用 |
| `**bold**` | 記号を除去し、`updateTextStyle` の `bold: true` を適用 |
| 箇条書き `- item` | 記号を除去し、`createParagraphBullets` を適用 |

実装のコツ:
- テキスト生成時に段落（1行 = 1セグメント）と「適用するスタイル種別 / mono / bold」を同時に記録する中間データ構造を作ると、インデックス計算と style リクエスト生成が一括でできる
- 連続する mono 段落はまとめて 1 つの `updateTextStyle` range にして、リクエスト数を削減する
- 完成後は実際にブラウザで開いて視認確認すること（マークダウン記号が残っていないか、見出しが太字化されているか）

### 5. フォルダへの移動

```bash
gws drive files update --params '{"fileId": "<DOC_ID>", "addParents": "<フォルダID>", "removeParents": "root"}' --json '{}'
```

### 6. 完了報告

ドキュメントのURLを表示して完了を報告する。
URL形式: `https://docs.google.com/document/d/<DOC_ID>/edit`
