# Raim Slides — レイアウト・カタログ

各レイアウト関数の引数仕様。`const D = require("./raim_helpers")(require("./theme"));` で取得し `D.xxxSlide(pres, {...})` で呼ぶ。
本文系は共通で `sectionNo`(章番号文字列)・`sectionName`(章名) を受ける。実例は `build_example.js`。

## 表紙・区切り・裏表紙（マスター不使用・ページ番号なし）

### `coverSlide(pres, opts)`
- `bigTitle` 大見出し（\n で改行可）／`subtitle`／`audience`／`date`／`confidentiality`（既定 theme.confidentialLabel、公開時 `"TLP:CLEAR"`）

### `dividerSlide(pres, opts)`
- `sectionNo`（薄緑の大番号）／`title`（白の章タイトル）。背景 濃緑。

### `closingSlide(pres, opts)`
- `message`（既定 "Thank you"）。会社情報は theme.company から自動。背景 濃緑。

## 本文（RAIM_BODY マスター／ページ番号自動）

### `agendaSlide(pres, opts)`
- `title`（大見出し＝leadText）／`items: [{ no, name }]`（章番号タグ＋章名のリスト）

### `bulletSlide(pres, opts)`
- `sectionNo, sectionName, title, takeaway, bullets: ["..."]`。`**強調**` 可。

### `execSummarySlide(pres, opts)`
- `title, takeaway, bullets:[], exhibits:[{label,title,source}](最大3), decide, next`
- 1pager。bullets の下に Exhibit カード、最下に ▶Decide / ▶Next。

### `meceCardsSlide(pres, opts)`
- `title, sub, cards:[{no,heading,body}](3〜5枚), summary`
- 3枚=横3列、4〜5枚=2列。summary は最下の ▶ 帯。

### `pyramidSlide(pres, opts)`
- `title, conclusion(濃緑帯), supports:["..."](3つ程度), facts:[{label,title,source}](2つ程度)`

### `numbersSlide(pres, opts)`
- `title, takeaway, metrics:[{value,unit,label,note}](3〜4個)`
- 大きな数字＋単位＋ラベル＋注記のカード横並び。

### `comparisonSlide(pres, opts)`
- `title, sub, left:{label, points:[]}, right:{label, points:[]}`
- 左=濃緑ヘッダ／右=最濃緑ヘッダの2カラム。points は em-dash。

### `timelineSlide(pres, opts)`
- `title, sub, phases:[{label, title, items:[]}]`
- フェーズ帯（緑→濃緑→最濃緑）＋ ▶ 矢印。

### `tableSlide(pres, opts)`
- `title, takeaway, headers:[], rows:[[...]], colWidths:[]`
- ヘッダ濃緑・偶奇縞。5行程度まで。`autoPage:false`。

### `figureSlide(pres, opts)`
- `title`（leadText）／任意 `takeaway`(濃緑帯)・`sub`(灰サブ行)／`image:{path}`／任意 `note`(最下部の ▶ 淡緑帯)
- `image` を本文域に**アスペクト維持でフィット&センタリング**配置（画像実寸を `image-size` で取得）。drawio 等で作った構造図を貼るためのレイアウト。
- 図を主役にするなら `takeaway`/`sub` を省いて `title + image + note` にすると図が本文域いっぱいに広がる。
- ワークフロー: `*.drawio`（正本）→ `drawio -x -f png -s 3 -b 12 fig.drawio` → `image.path`。配色は theme と統一。`codex exec -i <png>` で投影可読性をレビュー。

## 書き出し

```js
await D.writeDeck(pres, "out.pptx");  // pres.writeFile + ページ番号フィールドの焼き込み
```

`pres.writeFile()` を直接呼ぶとページ番号が付かないので、必ず `writeDeck` を使う。
