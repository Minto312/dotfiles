---
name: documentation
description: 最終的に人に見せる資料（HTML の artifact と PDF、Claude Docs、スライド）を作る・直すときの手順と注意。A4 の紙で渡す資料を artifact でも同じ見た目で見せる作り方、PDF の出力と確かめ方、artifact のコメントでの直し方、手元の機械（lenovo）への送り方。「資料を作って」「PDF にして」「artifact にして」「ペラ1枚で」「先方向けの資料」「印刷すると崩れる」「改ページがおかしい」「余白を配分して」などで起動。今は共通と HTML の節だけがあり、Docs とスライドの節は追記していく。
---

# documentation — 人に見せる資料の作り方

先方・上司・取引先など、最終的に人に見せる資料を作るときの決まりと知見をまとめる。
形式ごとに節を分ける。今あるのは「共通」と「HTML（A4 の紙と artifact）」で、「Docs」と「スライド」はこれから追記する。

## 1. 共通（どの形式でも）

### 書き方

- 見出しは、その節の結論を述べる文にする。「概要」「費用」のような分類名だけの見出しにしない。
- 日本語の決まりは `~/.claude/CLAUDE.md` の「文章」に従う。比喩を使わず、一文に一つの内容を書く。
- 一つの段落は一行で書く（ソースの中で段落の途中に改行を入れない）。HTML では、行の途中の改行が全角文字の間に余分な空白として出る。

### 中身

- 金額・日数・料金は、公式の案内で確かめてから書く。出典と確認日を資料の末尾に書く。
- 分からないことは「確認中」と書く。推測で埋めない。
- ユーザーが決めていない金額・約束・可否は書かない。決めることは AskUserQuestion で聞く。
- 比較の行や注記を消す依頼で、読み手の判断に関わる情報が資料から無くなるときは、何が無くなるかをユーザーに伝える。消すかどうかはユーザーが決める。
- 社内向けの事情（相手を批判する材料、内部の原価など）を資料に入れない。

### 確かめ方

- 渡す前に、必ず画像にして目で見る。ページ数、はみ出し、重なり、1〜2 字だけ次の行に落ちた行を確かめる。
- 「N 行に収めて」と言われたら、実際に描画して行数を数える。文字数の見積もりだけで決めない。

## 2. HTML（A4 の紙で渡す資料と、その artifact）

### 2-1. 方針: 紙（PDF）と artifact を同じ見た目にする

- ソースは PDF 用の HTML を正本にする。artifact は、それと同じ CSS と本文で、A4 の紙を画面に並べて表示する。
- 画面で読む用に別のデザインを作らない。画面と印刷の見た目が違うと、どちらを直せばよいかが分からなくなる。
- 変更は、PDF 用の HTML と artifact の両方に入れる。両方に効くセレクタ（`.page.p1 h2` など）で書くと、同じ CSS をそのまま貼れる。
- 雛形は `templates/a4-artifact.html` にある。

### 2-2. 紙の作り方（CSS）

- 1 枚を `.page { width: 210mm; height: 297mm; overflow: hidden; position: relative; }` にする。`@page { size: A4; margin: 0; }` と、`.page` ごとの改ページ（`break-after: page`）を入れる。
- `height` を固定するのは、`min-height` だと溢れた分が次のページへ流れて、ページ数が勝手に増えるからである。
- `overflow: hidden` なので、はみ出した分は何も言わずに切れる。直すたびに画像で確かめる。
- ページ番号は `.pnum` を `position: absolute; bottom: 2.5mm;` で置く。本文が下まで来ると重なるので、最後の行とページ番号の間を確かめる。
- フォントは Web フォント（Google Fonts の Noto Sans JP）を先頭に書く。
  - develop にある Noto Sans CJK JP は Windows には無い。Windows で開くと別のフォントになり、字の幅が変わって 2 ページ目の下端が切れた。
  - PDF 用の HTML にも `<link href="https://fonts.googleapis.com/css2?family=Noto+Sans+JP:wght@400;600;700&display=swap">` を入れ、artifact と同じフォントで出力する。
- 余白を紙面に配分するときは、ページごとに上書きの指定を足す（`.page.p1 { font-size: … }`、`.page.p1 h2 { margin: … }` など）。
  - 一度に大きくしすぎると溢れる。2〜3 回に分けて描画しながら合わせる。
  - 表の 1 セルの行数を保つ指示があるときは、表の文字を据え置き、行の上下の余白と節の間で配分する。

### 2-3. PDF の出力と確かめ方

```bash
google-chrome --headless --disable-gpu --no-sandbox --no-pdf-header-footer \
  --virtual-time-budget=8000 \
  --print-to-pdf="<出力>.pdf" "file://$PWD/<ソース>.html"
pdfinfo "<出力>.pdf" | grep Pages                 # ページ数
pdftoppm -png -r 80 "<出力>.pdf" /tmp/p           # 各ページを画像にして Read で見る
pdftoppm -png -r 110 -f 2 -l 2 -y 900 -H 300 -W 909 "<出力>.pdf" /tmp/crop   # 一部だけ拡大
```

- `--virtual-time-budget` を付けないと、Web フォントを読み込む前に出力されることがある。
- Web フォントを使うと PDF は 2MB 前後になる。文字は `pdftotext` で取り出せる。
- artifact の印刷結果と PDF が同じかは `scripts/check-print.sh <artifact.html> <PDF>` で比べる。公開時の外枠に近い形で包んで印刷し、ページごとに画素の差を数える。差が数画素なら同じと見てよい。

### 2-4. artifact 版の作り方

- 雛形 `templates/a4-artifact.html` を写し、`<main class="sheets">` の中に PDF 用 HTML の `.page` をそのまま入れる。
- 画面の幅が 210mm より狭いときは、スクリプトで紙ごと縮小する（`zoom` に `min(1, 使える幅 / 210mm)` を入れる）。印刷のときは `zoom: 1 !important` に戻す。
- テーマ（ダーク表示）に合わせるのは紙の外の背景だけにする。紙は白のまま、文字の色も変えない。
- 公開前のチェックリストは artifact-design の決まり（`<title>`、色のトークン、左右の余白など）に従う。雛形はそれを満たしている。

### 2-5. 印刷できる範囲の限界

- claude.ai の artifact の画面で Ctrl+P を押すと、印刷されるのは claude.ai のページである。artifact は枠（iframe）の中にあり、画面に見えている高さで切れる。
- これは artifact の中の CSS（`@media print` など）では直せない。手元で iframe に入れたページを印刷して確かめた。
- 印刷や配布には PDF を使ってもらう。artifact は画面で読む用と伝える。
- ユーザーが「改ページがおかしい」と言ったら、まずどこから印刷したか（artifact の画面か、HTML を直接開いたか、PDF か）を聞く。手元の Chrome で HTML を直接印刷して確かめただけで「直った」と言わない。

### 2-6. artifact のコメントで直すとき

- コメントには自動の返信が先に付く。自動の返信は依頼を読み違えることがあるので、スレッドを読んで判断する。
  - 選択した文字（`[on text]`）に短い語だけが書かれていたら、選択した部分をその語に置き換える依頼である。段落を消す依頼ではない。例: 「なくせて、」に「消せ、」→ 置き換える。
  - 「削除」は、選択した範囲だけを消す依頼である。周りの段落や注記の全体を消す依頼ではない。
  - 自動の返信が読み違えていたら、そのスレッドに訂正を返信する（`acknowledge_duplicate: true`）。
- 直したら、PDF 用の HTML と artifact の両方に入れ、PDF を作り直し、`scripts/check-print.sh` で両者が同じことを確かめる。
- 小さい変更は Artifact の publish の `edits` で入れる。`old_str` は一意にし、行ごと消すときは行末の改行まで含める。
- 終わったスレッドは resolve する。ユーザーが「一旦」などと書いて、続けて決める様子があるときは開けておく。
- 消した結果、資料から無くなった情報（お問い合わせ先、費用の内訳など）があれば、ユーザーに伝える。

### 2-7. 手元の機械（lenovo）へ送って開く

```bash
pdf="<出力>.pdf"
scp -q -o BatchMode=yes "$pdf" "lenovo:Downloads/"
name=$(basename "$pdf")
enc=$(printf '%s\n%s' '[Console]::OutputEncoding = [Text.Encoding]::UTF8' \
  "\$p = Join-Path \$env:USERPROFILE 'Downloads\\$name'; Start-Process \$p" \
  | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
ssh -o BatchMode=yes lenovo-interactive "pwsh -NoProfile -EncodedCommand $enc"
```

- `lenovo-interactive` はログオン中のデスクトップで実行される。`lenovo` で実行すると画面に出ない。
- PowerShell には `-EncodedCommand`（UTF-16LE を base64 にしたもの）で渡す。日本語のファイル名もこれで通る。
- 前の版をビューアで開いたまま上書きすると、表示が古いままになる。開き直してもらう。
- 「送って」と言われたときは、送ったあとに開くところまで行う。直すたびの上書きでは開かなくてよい。

## 3. Docs（Claude Docs）

（未記入。知見がたまったら追記する）

## 4. スライド

（未記入。知見がたまったら追記する）

関係するスキル: Raim のブランドで作るなら `raim-slides`、ブランドに依らない作り方は `slidecraft`、Google Slides は `slide-deck`、pptx を Windows の Office で描画して確かめるなら `office-render`。

## 記録

- 2026-11-15: 先方向けの A4 2 枚の資料（PDF と artifact）を、コメントで 20 回ほど直したときの知見から作った（共通・HTML の節）。
