---
name: slide-deck
description: コンサルファーム品質（McK/BCG/Bain風）のGoogle Slidesデッキを作成する。「スライド作って」「プレゼン資料を作って」「提案書をスライドに」「デッキを生成」などで起動。
disable-model-invocation: false
allowed-tools: Bash, Read, Write, Edit
---

# slide-deck — コンサル品質Google Slidesデッキ生成

McKinsey Executiveスタイル（So Whatタイトル / Exhibit規律 / 高密度クリーン）を踏襲したGoogle Slidesを `gws` 経由で生成する。

## 設計思想（必読）

詳細は `design_spec.yaml` 参照。要点:

- **So Whatタイトル**: 全スライドのタイトルは結論を断定する一文（説明タイトル禁止）
- **1スライド1メッセージ**: 主張は1つに絞る
- **Exhibit規律**: 主張には必ず根拠Exhibit（最大3／枠付き／出典必須）
- **ゾーン設計**: title / summary / exhibit / implication の4ゾーンで読み順を固定
- **黒面積予算**: 全体の15〜20%以下（帯/小パネル中心、全面黒は禁止）
- **配色制約**: ニュートラル（白/黒/灰）+ アクセント1色（青 or 金）まで

## ワークフロー（必ずこの順序で実行）

ユーザーから「スライド作って」系の依頼を受けたら、**勝手に生成し始めない**。以下を順守する。

### Step 1: 構成提案（deck_architecture）

ユーザーの目的・トピック・聞き手をヒアリングしてから、`design_spec.yaml` の `deck_architecture.order` に沿った構成案を提示する:

```
1. Cover
2. Executive Summary
3. Situation & Objective
4. Key Findings (MECE)
5. Implications / Options
6. Recommendation
7. Implementation Plan
8. Risks & Mitigations
9. Appendix
```

各章について:
- レイアウト型（`templates/manifest_schema.md` 参照）
- 1〜2行の含意

を箇条書きで提示し、**ユーザー承認を得る**。不要な章はスキップ提案する（短いデッキならExec Summary + Recommendation のみ等）。

### Step 2: 各スライドのコンテンツドラフト

承認後、スライドごとに:
- **タイトル（So What）**: 結論を断定。可能なら数値/比較語を含める（+3pt, 2x, Top-2 等）
- **takeaway** / **bullets** / **exhibits** / **implications**: ゾーン別に内容
- **Exhibitのsource/notes**: 出典・期間・単位は必須

をmanifest YAMLで起こす。長いデッキなら章単位で分割提示し、都度確認する。

### Step 3: manifest確定 → 生成

ユーザー確認後、`{deck_name}.yaml` として保存し、以下で生成:

```bash
# 生成（PyYAMLはuvが自動解決）
uv run --quiet --script ~/.claude/skills/slide-deck/lib/builder.py {deck_name}.yaml --tag v1

# バリデーションのみ（API呼ばない）
uv run --quiet --script ~/.claude/skills/slide-deck/lib/builder.py {deck_name}.yaml --dry-run
```

`--tag` を使うとデッキタイトルに `(v1)` 等の version 接尾辞が付き、繰り返し生成時に Drive 上で識別しやすい。

### Step 4: Visual Polish via API Patches（必要時）

builder.py は決定論的な土台を作るが、スライド毎の固有調整・美的判断は Slides API を直接 patch で行う。

**ワークフロー:**
1. PDF エクスポートして全ページ画像レビュー
2. 問題箇所を特定
3. 直接 `gws slides presentations batchUpdate` で patch を発行
4. 再エクスポート → 確認 → 必要ならループ

**要素の特定方法（3パターン）:**

(a) **テキスト全文置換** — 要素特定不要
```bash
gws slides presentations batchUpdate --params "{\"presentationId\":\"$PID\"}" --json '{
  "requests": [
    {"replaceAllText": {"containsText": {"text": "X"}, "replaceText": "Y"}}
  ]
}'
```

(b) **alt-text で要素を検索** — builder.py が主要要素に `pageElement.title` で semantic name を埋めている。
```bash
# 例: "s1.cover.project_code" を持つ要素を検索
gws slides presentations get --params "{\"presentationId\":\"$PID\"}" --format json 2>/dev/null | \
  python3 -c "
import sys, json
pres = json.load(sys.stdin)
for sl_idx, sl in enumerate(pres.get('slides', []), 1):
    for el in sl.get('pageElements', []):
        if 'project_code' in el.get('title', ''):
            print(sl_idx, el.get('objectId'), el.get('title'))
"
```

builder.py が現在埋めている主な name:
- `s{N}.title` — スライドのタイトル
- `s{N}.header.chip` / `header.section_name` — ヘッダchip / section名
- `s{N}.cover.project_code` — Cover/Closingのproject_code

(c) **位置・サイズで特定** — alt-text が無い要素は `pageElement.transform.translateX/Y` と `size` で識別。

**代表的な patch:**

| 操作 | request type |
|---|---|
| 削除 | `deleteObject` |
| 移動・サイズ | `updatePageElementTransform` / 直接 `updateShapeProperties` |
| 色変更 | `updateShapeProperties.shapeBackgroundFill` / `outline` |
| テキスト書換 | `deleteText` + `insertText` |
| テキスト一括置換 | `replaceAllText` |
| 要素追加 | `createShape` + `insertText` + style |

**実例:**
```bash
PID="<presentation_id>"

# 1. project_code 全部削除（Cover/Closing から）
gws slides presentations batchUpdate --params "{\"presentationId\":\"$PID\"}" --json '{
  "requests": [
    {"deleteObject": {"objectId": "tx_xxxxx"}},
    {"deleteObject": {"objectId": "tx_yyyyy"}}
  ]
}'

# 2. 特定要素の塗り色を変更
gws slides presentations batchUpdate --params "{\"presentationId\":\"$PID\"}" --json '{
  "requests": [
    {"updateShapeProperties": {
      "objectId": "rc_zzzzz",
      "shapeProperties": {
        "shapeBackgroundFill": {"solidFill": {"color": {"rgbColor": {"red": 0.094, "green": 0.169, "blue": 0.565}}}}
      },
      "fields": "shapeBackgroundFill.solidFill.color"
    }}
  ]
}'
```

**重要:**
- patch 後は必ず PDF を再エクスポートして視覚確認
- 構造的・大規模な修正は manifest YAML を編集して再生成（v2, v3...）
- patch は「最後の磨き」用途。あまりに多くの patch が必要なら manifest 側で対処

## 起動時の最初の一言

skillが起動したら、まずこう確認する:

> デッキ作成にあたり、以下を教えてください:
> - **目的**（説得 / 報告 / 議論）
> - **聞き手**（経営層 / 現場 / 社外クライアント等）
> - **トピック**（タイトル相当）
> - **既存資料の有無**（あれば参照）
> - **目安ページ数**

その上でStep 1の構成案を出す。

## 利用可能なレイアウト型

`templates/manifest_schema.md` に各型のmanifest形式を定義済み:

- `Cover_Consulting` — 表紙
- `ExecSummary_1pager` — エグゼクティブサマリー1枚
- `KeyFindings_MECE_3to5` — MECE論点（カード3〜5）
- `Pyramid_Principle` — 結論→根拠→事実の階層
- `Options_2col_Tradeoff` — 選択肢比較（2列）
- `Rec_Recommendation` — 推奨案断定
- `Roadmap_Gantt_Light` — 実行計画（軽量ガント）
- `Risks_Mitigations_Table` — リスク管理表
- `Appendix_Exhibits` — Appendix（1スライド1Exhibit）

## ガードレール（生成前に自己チェック）

以下に違反していたら **生成前に直す**:

- [ ] 全タイトルが結論断定（「〜について」「〜の概要」が無い）
- [ ] 1スライドのExhibit数 ≤ 3
- [ ] Exec Summaryのbullets ≤ 3
- [ ] 各Exhibitに source（出典・期間・単位）
- [ ] アクセント色は青か金の **どちらか1色のみ**
- [ ] 全面黒のスライドが無い（黒は帯/パネル運用）
- [ ] 章番号は01-09 / Appendixは A1, A2…

## 関連

- `gws` skill — Google Slides APIへのアクセスに利用
- `export-gdocs` skill — 同じAPI基盤を使うDocs版
