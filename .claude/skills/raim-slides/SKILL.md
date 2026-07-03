---
name: raim-slides
description: 株式会社Ｒａｉｍテクノロジーズのコーポレート・スライド(PPTX)をブランド標準フォーマットで作成する。緑のブランドカラー(#1DBD4D)・ロゴ・TLPフッター・スライドマスター(プレースホルダ)を備えた theme駆動の PptxGenJS テンプレート。「Raimのスライド作って」「会社案内」「提案書のたたき台」「会社紹介のデッキ」「pptx作って」などRaim社の社内/対外スライド作成で起動。汎用の slidecraft より Raim 案件ではこちらを優先する。
---

# Raim Slides — Raim コーポレート・スライド作成スキル

株式会社Ｒａｉｍテクノロジーズのブランド標準 PPTX を作る。**theme 駆動の PptxGenJS テンプレート**で、配色・ロゴ・会社情報は `theme.js` の1ファイルに集約。
slidecraft の「良いスライドの原則」を踏襲しつつ、Raim ブランド（緑アクセント・ロゴ・TLP フッター・スライドマスター）を適用したブランド専用スキル。

- **配色トーン**：白基調・本文チャコール、アクセントにブランド緑 `#1DBD4D`、帯/章扉に濃緑 `#13A13E`（「上品ミックス」）
- **PowerPoint 編集前提**：章番号・スライドタイトル・リード文は**プレースホルダー**、ページ番号は**自動採番フィールド**、共通フッターは**マスター由来**。生成後に PowerPoint で手修正してもブランド書式・番号が崩れない
- **正本はスクリプト**：新規スライドは原則 build スクリプトに追記して再生成する（jings-slides と同じ思想）

## 前提

公開 pptx スキル（`/mnt/skills/public/pptx/SKILL.md`、無ければ pptxgenjs の基本）の上に構築される。Node + `pptxgenjs`、PDF確認用に `soffice`(LibreOffice)、ロゴの後処理に ImageMagick を使う。

---

## クイックスタート

> ⚠️ **スキル本体 (`~/.claude/skills/raim-slides/`) は読み取り専用のテンプレート。デッキ作成はスキル内では行わない。**
> 作業ディレクトリを切り、テンプレ一式をそこへコピーしてから作業する（成果物・`node_modules` をスキルに混ぜないため）。

```bash
# 1. 作業ディレクトリを切る（現在の作業ディレクトリ配下。無ければ ~/workspace/tmp を推奨）
WORK="${PWD}/tmp/raim-slides"            # 案件名に置き換えてよい
#   WORK=~/workspace/tmp/jings-slides    # 推奨: workspace の tmp 配下
mkdir -p "$WORK"

# 2. テンプレ一式をコピー（成果物・node_modules は持ち込まない）
rsync -a --exclude node_modules --exclude _preview \
      --exclude '*.pptx' --exclude '*.pdf' \
      ~/.claude/skills/raim-slides/ "$WORK/"
cd "$WORK"

# 3. 依存導入 → 見本デッキ生成 → PDF で目視確認（すべて作業ディレクトリ内で完結）
npm install                 # 初回のみ（pptxgenjs / jszip）
node build_example.js       # 見本デッキ（全12レイアウト）を生成
soffice --headless --convert-to pdf --outdir . Raim_Template_2026.pptx   # 目視確認
```

### 自分のデッキを作る

**作業ディレクトリ内で** `build_example.js` をコピーして中身を書き換える（相対 require のまま動く）。

```js
const D = require("./raim_helpers")(require("./theme"));
D.setDeck({ title: "○○社 御中 ご提案" });   // 本文ヘッダ右上に出る通し名（createPresentation より前に呼ぶ）
const pres = D.createPresentation("提案書");  // 内部で RAIM_BODY マスターを定義

D.coverSlide(pres, { bigTitle: "...", subtitle: "...", audience: "...", date: "2026" });
D.execSummarySlide(pres, { sectionNo: "01", sectionName: "Summary", title: "...", takeaway: "...",
                           bullets: ["..."], exhibits: [{label,title,source}], decide: "...", next: "..." });
await D.writeDeck(pres, "out.pptx");          // writeFile + ページ番号をレイアウトへ焼き込み（pres.writeFile では番号が付かない）
```

図版（drawio/png）・トークスクリプト等の案件成果物もすべて作業ディレクトリに置く。**スキルディレクトリには書き戻さない。**
build スクリプトごと残したい場合は、作業ディレクトリを `~/workspace/raim/<案件名>/` などへ移して保存する。

---

## 処理フロー（設計 → レビュー → 生成）

ブランド/テーマは確定済みなので、slidecraft の STEP 0 は不要。STEP 1〜4 を回す。

```
STEP 1: インプット収集 … 目的・聞き手・「何にYESしてほしいか」
STEP 2: ストーリー設計 … 構成表を出して【ユーザー確認】（タイトル＝結論ライン、目的→結論→根拠が一直線か）
STEP 3: 品質レビュー … 各スライドを「1スライド1メッセージ／タイトル2層／So-What(▶)／視認性」で採点
STEP 4: 生成 … build スクリプトで生成 → PDFで目視確認（テーブル溢れ・タイトル折返し・余白）
```

**STEP 2 の構成表は必ずユーザー確認を取ってから STEP 3・4 に進む。**

---

## レイアウト一覧（12種）

本文レイアウトは共通で `sectionNo`(章番号)・`sectionName`(章名) を受ける（`cover`/`divider`/`closing` を除く）。

| 関数 | 用途 | 主な引数 |
|---|---|---|
| `coverSlide` | 表紙 | `bigTitle, subtitle, audience, date, confidentiality` |
| `agendaSlide` | 目次 | `title, items:[{no,name}]` |
| `dividerSlide` | 章扉（濃緑） | `sectionNo, title` |
| `execSummarySlide` | エグゼクティブサマリ 1pager | `title, takeaway, bullets, exhibits:[{label,title,source}], decide, next` |
| `meceCardsSlide` | MECE カード（3〜5枚） | `title, sub, cards:[{no,heading,body}], summary` |
| `pyramidSlide` | ピラミッド（結論→根拠→事実） | `title, conclusion, supports:[], facts:[{label,title,source}]` |
| `numbersSlide` | 数値ハイライト（KPI 3〜4） | `title, takeaway, metrics:[{value,unit,label,note}]` |
| `comparisonSlide` | 比較（2カラム） | `title, sub, left:{label,points}, right:{label,points}` |
| `timelineSlide` | タイムライン/ロードマップ | `title, sub, phases:[{label,title,items}]` |
| `bulletSlide` | 箇条書き本文 | `title, takeaway, bullets` |
| `tableSlide` | 表（ヘッダ濃緑・偶奇縞） | `title, takeaway, headers, rows, colWidths` |
| `figureSlide` | 図版（drawio 等の外部図をフィット配置） | `title, takeaway, sub, image:{path}, note` |
| `closingSlide` | 裏表紙（会社情報） | `message` |

> **`figureSlide` の図は drawio で作る**：`*.drawio` を正本に、`drawio -x -f png -s 3 fig.drawio` で PNG 化して `image.path` に渡す。
> 配色は theme と揃える（STEP=緑 `#1DBD4D` / 到達点=濃緑 `#0B6E2B` / 矢印・強調=`#13A13E` / 淡背景=`#EAF7EE`）。
> 図は本文域に**アスペクト維持でフィット&センタリング**されるため、本文域(約4:1)に合わせ横長(ar≈3.3)に作ると幅いっぱいに収まる。
> 例: `fig-nextaction.drawio`（「積み上げ階段」図）。`codex exec -i <png>` で投影可読性をレビューして詰めると速い。

- 文字列中の `**強調**` は太字 run に変換される。
- 箇条書きは em-dash（—）プレフィックス方式。
- 件数・文字量の制約は [references/design-system.md](references/design-system.md) を参照（カードは3〜5枚、表は5行目安 等）。

---

## PowerPoint 編集時の挙動（重要）

本文スライドは `RAIM_BODY` マスター/レイアウトを使う。以下はすべて**レイアウト由来**で、PowerPoint で手修正しても自動で揃う：

- **章番号(`slideNo`)・スライドタイトル(`slideTitle`)・リード文(`leadText`) はプレースホルダー** → 新規スライド（レイアウト「RAIM_BODY」）に入力枠が出る／アウトライン表示にも載る
- **ページ番号** は自動採番フィールド（`slidenum`）→ 挿入・削除・並べ替えで自動で振り直し（章扉を挟むと1つ飛ぶ）
- **共通フッター**（罫線・TLP・© 株式会社Raimテクノロジーズ）・**右上デッキ名**・**背景** もマスター由来

表紙・章扉・裏表紙はこのレイアウトを使わず、番号も出ない。

---

## TLP（機密度）運用

- フッター左に機密ラベルを自動表示（既定 `theme.confidentialLabel = "TLP:AMBER"`）
- 公開資料は `coverSlide({ confidentiality: "TLP:CLEAR" })` で個別指定、または theme 既定を差し替え
- 印鑑画像・口座番号など TLP:RED 相当はこのテンプレートに載せない

---

## ⚠ 要確認のプレースホルダ（theme.js の company）

確定したら差し替える:
- `email: "info@raim-tech.com"`（会社代表アドレス）／ `url: "https://raim-tech.com"`（コーポレートサイト）
- 英語タグラインがあれば `theme.logo.tagline` に設定すると表紙・ヘッダに反映

---

## スキル構成 / 正本

```
raim-slides/
├── SKILL.md
├── theme.js              # 配色・フォント・ロゴ・会社情報（ここだけ直せば配色が変わる）
├── raim_helpers.js       # theme駆動の12レイアウト関数 + writeDeck（ページ番号焼き込み）
├── build_example.js      # 見本デッキ生成（全レイアウト1枚ずつ）
├── package.json          # pptxgenjs / jszip
├── assets/               # ロゴ4種（通常＋白抜き）
└── references/
    ├── design-system.md  # 配色・原則・マスター/プレースホルダ・既知の制約
    └── layout-catalog.md  # 各レイアウトの引数詳細
```

**このスキルは読み取り専用のテンプレート（配布版）。** デッキ作成はスキル内では行わず、作業ディレクトリにコピーして行う（→[クイックスタート](#クイックスタート)）。`build_<案件>.js`・図版・pptx などの成果物をスキルディレクトリに残さないこと。

開発元は `~/workspace/raim/slide_template/`（出力 pptx/pdf 付き）。配色やレイアウトを更新したら両者を同期する（このスキルを正本にしてよい。更新はテンプレ本体＝`theme.js` / `raim_helpers.js` / `build_example.js` / `references/` に限る）。
