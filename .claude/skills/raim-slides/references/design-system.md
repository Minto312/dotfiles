# Raim Slides — デザインシステム

配色・タイポ・レイアウト原則・スライドマスター仕様・既知の制約。すべて `theme.js` と `raim_helpers.js` の実装に対応する。

## 配色トークン（theme.js）

| トークン | 値 | 用途 |
|---|---|---|
| `primary` | `1DBD4D` | ブランド緑：アクセント下線・章番号タグ・見出しバー・▶マーカー |
| `primaryLight` | `7FE3A1` | 濃緑背景上のラベル・章扉番号 |
| `primaryDark` | `13A13E` | 濃緑：takeaway 帯・テーブルヘッダ・章扉/裏表紙背景 |
| `navy` | `0B6E2B` | 最濃緑（比較の右カラム・ロードマップ後期）※名称は slidecraft 互換、実体は緑 |
| `text` | `2E2E2E` | タイトル・本文（ロゴ文字色と一致） |
| `textGray` | `707070` | サブ見出し・ページ番号 |
| `accent` | `E03535` | 注意・機密枠（赤） |
| `panelBg` | `EAF7EE` | 淡い緑パネル（カード・結論ボックス背景） |
| `lightGray` | `F4F7F5` | テーブル偶奇縞・プレースホルダ背景 |
| `border` | `DDDDDD` | 罫線・枠線 |
| `copyright` | `9A9A9A` | 白地フッターのコピーライト |
| `footerOnDark` | `DCEFE2` | 濃緑地フッターのコピーライト |

色コードはヘルパー内に直書きせず、必ず `theme.colors` から引く。別ブランドへ移植する場合はこの表と `logo`/`company` を差し替える。

## フォント

`Yu Gothic UI` → 無ければ `Meiryo UI` → `Noto Sans CJK JP` に自動フォールバック（`raim_helpers.js` 冒頭の `resolveFont`、引数 theme は破壊しない）。英字キャプション・ページ番号は `Calibri`。

## レイアウト原則（slidecraft 準拠）

1. **1スライド1メッセージ**
2. **タイトル2層**：スライドタイトル（章名）＋ リード文（結論ライン、太字メッセージ）。必要に応じ takeaway 帯（濃緑）で結論を補強
3. **So-What は ▶ で示す**（「示唆」の語は使わない）
4. **特徴→便益**、便益は可能なら定量（仮値は「(仮)」明示）
5. **視認性**：本文は詰めすぎない。詳細は Appendix へ

座標系は 16:9（W=10, H=5.625 inch）、本文セーフエリア下端 `BODY_BOTTOM=4.92`。

## スライドマスター / プレースホルダ仕様

本文は `defineSlideMaster` で **`RAIM_BODY`** マスター/レイアウトを使う。共通要素はすべてレイアウトの図形 or プレースホルダとして焼き込み、PowerPoint の新規スライドにも継承される。

| 要素 | 種別 | name / idx | 位置・書式 |
|---|---|---|---|
| 章番号タグ | プレースホルダ(body) | `slideNo` | 左上・緑背景・白文字中央・13pt |
| スライドタイトル | プレースホルダ(title) | `slideTitle` | 緑タグ右・13pt 太字チャコール |
| リード文 | プレースホルダ(body) | `leadText` | 罫線下 y=1.04・14pt 太字チャコール |
| ヘッダ罫線・フッター罫線 | 通常図形(line) | — | 緑 y=0.9 / グレー y=H-0.40 |
| 右上デッキ名 | 通常図形(text) | — | `DECK.title`・9pt グレー右寄せ |
| TLP ラベル | 通常図形(text) | — | 左下・`confidentialLabel` |
| © 株式会社Raimテクノロジーズ | 通常図形(text) | — | 中央下・`company.copyright` |
| ページ番号 | 自動採番フィールド | `RaimPageNum` | 右下・`slidenum` fld・`anchor="ctr"`（© と縦位置を揃える） |

- ヘルパーは `s.addText(text, { placeholder: "slideNo" \| "slideTitle" \| "leadText" })` で各プレースホルダに流し込む。
- **ページ番号は `writeDeck()` の後処理**で、`RAIM_BODY` レイアウト（`name="RAIM_BODY"` で特定）の spTree に `slidenum` フィールドの通常図形を jszip で注入する。PptxGenJS の `slideNumber`（プレースホルダ方式）は新規スライドに継承されないため使わない。
- 表紙・章扉・裏表紙は `pres.addSlide()`（デフォルトマスター）＋ 自前フッターで、ページ番号は出さない。

## 既知の制約（生成前に守る）

- **MECE カードは 3〜5 枚**（`cols = n<=3 ? n : 2`）。1〜2枚や6枚以上はレイアウトが想定外。
- **表は 1 枚あたり 5 行程度**まで。溢れたら分割（`autoPage:false` で自動改ページは抑止済み）。
- **タイトルは1行に収める**（長いと折返して罫線にかかる）。
- 本文ボックス（カード body・pyramid supports・bullet・comparison）は `fit:"shrink"` で自動縮小するが、過度な長文は溢れる。1項目は簡潔に。
- `parseBold` は `**…**` の単純置換。ネストや素の `*`（べき乗表記等）には未対応。
- `setDeck()` は `createPresentation()` より**前**に呼ぶ（デッキ名はマスター生成時に焼き込むため）。
- 1プロセス1デッキ前提（`DECK` はモジュールスコープ）。バッチ生成は別プロセスで。
