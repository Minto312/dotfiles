# Slidecraft レイアウト・パターン（PptxGenJS / theme 駆動）

すべてのヘルパーは色・フォントを `theme`（assets/theme.template.js）から引く。**色コードを直書きしない。** レイアウトは原則の範囲で裁量を持って選ぶ。

構成例：
```
project/
  theme.js            ← theme.template.js をコピーしてブランド色に
  deck_helpers.js     ← 下記の theme 駆動ヘルパー
  build_deck.js       ← require('./deck_helpers')(require('./theme')) して本編を書く
```

---

## deck_helpers.js（theme 駆動・コア）

```javascript
const pptxgen = require("pptxgenjs");
const { execSync } = require("child_process");

module.exports = function (T) {
  // ── フォントフォールバック（Yu Gothic UI 無ければ差替え）──
  try { execSync(`fc-list | grep -i '${T.fonts.header}'`, { stdio: "ignore" }); }
  catch {
    const fb = (() => { try { execSync("fc-list | grep -i 'Meiryo UI'", {stdio:"ignore"}); return "Meiryo UI"; } catch { return "Noto Sans CJK JP"; } })();
    T.fonts.header = fb; T.fonts.body = fb;
  }
  const C = T.colors, F = T.fonts;
  const W = 10, H = 5.625, ML = 0.5, MR = 0.5, CW = W - ML - MR;

  function createPresentation(title) {
    const p = new pptxgen(); p.layout = "LAYOUT_16x9"; p.title = title || "Deck"; return p;
  }
  // ページ自動採番（表紙=1扱い、区切りは採番しない）。main で const pg = counter();
  function counter() { let n = 1; return () => ++n; }

  function addLogo(slide, variant) {
    if (!T.logo) return;
    const img = variant === "light" ? T.logo.light : T.logo.dark;
    if (img) slide.addImage({ path: img, x: 0.2, y: 0.1, w: 0.85, h: 0.25 });
    if (T.logo.tagline) slide.addText(T.logo.tagline, { x: 1.1, y: 0.15, w: 2.4, h: 0.18, fontSize: 6.5, fontFace: F.tagline, color: variant === "light" ? "AACCFF" : C.copyright, margin: 0 });
  }
  function addFooter(slide, pres, pageNum, variant) {
    const fy = H - 0.32;
    slide.addText(`© ${T.year}  All Rights Reserved.`, { x: 0.3, y: fy, w: 3, h: 0.2, fontSize: 5.5, fontFace: F.tagline, color: variant === "light" ? "CCDDFF" : C.copyright, margin: 0 });
    if (T.confidentialLabel && variant !== "light") {
      slide.addShape("rect", { x: W - 1.55, y: fy, w: 0.85, h: 0.2, line: { color: C.accent, width: 0.6 }, fill: { color: C.white } });
      slide.addText(T.confidentialLabel, { x: W - 1.55, y: fy, w: 0.85, h: 0.2, fontSize: 6.5, fontFace: F.header, color: C.accent, align: "center", valign: "middle", margin: 0 });
    }
    if (pageNum) slide.addText(String(pageNum), { x: W - 0.55, y: fy, w: 0.35, h: 0.2, fontSize: 8, fontFace: F.tagline, color: C.textGray, align: "center", valign: "middle", margin: 0 });
  }

  function coverSlide(pres, { client, phase, subtitle, date }) {
    const s = pres.addSlide(); s.background = { color: C.white };
    addLogo(s, "dark");
    s.addText(client, { x: 0.6, y: 1.8, w: 6, h: 0.6, fontSize: 24, fontFace: F.header, color: C.primary, bold: true, margin: 0 });
    if (phase) s.addText(phase, { x: 0.6, y: 2.5, w: 6, h: 0.5, fontSize: 18, fontFace: F.header, color: C.primary, bold: true, margin: 0 });
    s.addText(subtitle, { x: 0.6, y: 2.95, w: 6, h: 0.5, fontSize: 20, fontFace: F.header, color: C.primary, bold: true, margin: 0 });
    s.addText(date, { x: 0.6, y: 3.6, w: 4, h: 0.3, fontSize: 13, fontFace: F.header, color: C.primary, bold: true, margin: 0 });
    addFooter(s, pres, null, "dark");
    return s;
  }

  // 標準コンテンツ枠（青アクセントバー＋タイトル＋メッセージライン）
  function contentSlide(pres, { title, message = "", pageNum }) {
    const s = pres.addSlide(); s.background = { color: C.white };
    addLogo(s, "dark");
    s.addShape("rect", { x: ML, y: 0.55, w: 0.06, h: 0.35, fill: { color: C.primary } });
    s.addText(title, { x: ML + 0.15, y: 0.5, w: 8.6, h: 0.45, fontSize: 18, fontFace: F.header, color: C.primary, bold: true, margin: 0 });
    s.addShape("line", { x: ML, y: 0.95, w: CW, h: 0, line: { color: C.primary, width: 0.5 } });
    if (message) s.addText(message, { x: ML, y: 1.05, w: CW, h: 0.35, fontSize: 11, fontFace: F.body, color: C.text, shrinkText: true, margin: 0 });
    addFooter(s, pres, pageNum, "dark");
    return s;
  }

  function dividerSlide(pres, { title }) {
    const s = pres.addSlide();
    s.background = T.dividerBg ? { path: T.dividerBg } : { color: C.primary };
    addLogo(s, "light");
    s.addText(title, { x: 0.6, y: 2.2, w: 8.6, h: 1.0, fontSize: 32, fontFace: F.header, color: C.white, bold: true, margin: 0 });
    addFooter(s, pres, null, "light");
    return s;
  }

  // 汎用テーブル（cell は文字列 or {text, options}）
  function addTable(slide, { headers, rows, x = ML, y = 1.5, w = CW, h, colWidths }) {
    const hr = headers.map(t => ({ text: t, options: { fill: { color: C.primary }, color: C.white, bold: true, fontSize: 10, fontFace: F.header, align: "center", valign: "middle" } }));
    const dr = rows.map((row, ri) => row.map(cell => {
      const base = { fill: { color: ri % 2 ? C.lightGray : C.white }, color: C.text, fontSize: 9, fontFace: F.body, valign: "middle", margin: [3, 5, 3, 5] };
      return (cell && typeof cell === "object" && "text" in cell)
        ? { text: cell.text, options: Object.assign(base, cell.options || {}) }
        : { text: String(cell), options: base };
    }));
    const tot = colWidths ? colWidths.reduce((a, b) => a + b, 0) : headers.length;
    const cw = colWidths ? colWidths.map(c => c / tot * w) : headers.map(() => w / headers.length);
    const rh = h ? [0.35, ...rows.map(() => (h - 0.35) / rows.length)] : [0.35, ...rows.map(() => 0.6)];
    slide.addTable([hr, ...dr], { x, y, w, colW: cw, border: { pt: 0.5, color: C.border }, rowH: rh });
  }

  // テーブル + 要点ボックス（▶ マーカー。「示唆」の語は使わない）
  function tableSlide(pres, { title, message = "", headers, rows, colWidths, takeaway, tableH, pageNum }) {
    const s = contentSlide(pres, { title, message, pageNum });
    const y = message ? 1.5 : 1.2;
    const h = tableH || Math.min(2.9, 0.4 + rows.length * 0.5);
    addTable(s, { headers, rows, x: ML, y, w: CW, h, colWidths });
    if (takeaway) {
      const cy = y + h + 0.12;
      s.addShape("rect", { x: ML, y: cy, w: CW, h: 0.6, fill: { color: C.panelBg }, line: { color: C.primary, width: 1 } });
      s.addText([{ text: "▶  ", options: { bold: true, color: C.primary } }, { text: takeaway, options: { color: C.text } }],
        { x: ML + 0.15, y: cy + 0.02, w: CW - 0.3, h: 0.56, fontSize: 9.5, fontFace: F.body, valign: "middle", margin: [2, 4, 2, 4] });
    }
    return s;
  }

  // 横並びステップフロー（step.accent で強調ノード、note で下部注記）
  function stepFlowSlide(pres, { title, message = "", steps, note, pageNum }) {
    const s = contentSlide(pres, { title, message, pageNum });
    const sy = 1.6, sh = 2.35, gap = 0.18;
    const sw = (CW - (steps.length - 1) * gap) / steps.length;
    steps.forEach((st, i) => {
      const sx = ML + i * (sw + gap);
      s.addShape("rect", { x: sx, y: sy, w: sw, h: 0.55, fill: { color: st.accent || C.primary } });
      s.addText(st.title, { x: sx, y: sy, w: sw, h: 0.55, fontSize: 9.5, fontFace: F.header, color: C.white, bold: true, align: "center", valign: "middle", margin: 2 });
      s.addShape("rect", { x: sx, y: sy + 0.55, w: sw, h: sh - 0.55, fill: { color: C.panelBg }, line: { color: C.border, width: 0.3 } });
      const items = st.items.map((it, j) => ({ text: it, options: { bullet: true, breakLine: j < st.items.length - 1, fontSize: 8.5, fontFace: F.body, color: C.text } }));
      s.addText(items, { x: sx + 0.08, y: sy + 0.62, w: sw - 0.16, h: sh - 0.7, margin: [3, 4, 3, 4] });
      if (i < steps.length - 1) s.addText("▶", { x: sx + sw, y: sy + 0.13, w: gap, h: 0.3, fontSize: 12, color: C.primary, align: "center", valign: "middle", bold: true, margin: 0 });
    });
    if (note) {
      const ny = sy + sh + 0.2;
      s.addShape("rect", { x: ML, y: ny, w: CW, h: 0.7, fill: { color: C.amberBg }, line: { color: C.amber, width: 1 } });
      s.addText([{ text: note.label + "  ", options: { bold: true, color: "B8860B" } }, { text: note.text, options: { color: C.text } }],
        { x: ML + 0.15, y: ny, w: CW - 0.3, h: 0.7, fontSize: 9.5, fontFace: F.body, valign: "middle", margin: [2, 4, 2, 4] });
    }
    return s;
  }

  // ロードマップ（短期/中期/長期 + 任意の詳細行）
  function roadmapSlide(pres, { title, message = "", phases, dataRows, pageNum }) {
    const s = contentSlide(pres, { title, message, pageNum });
    const cy = message ? 1.45 : 1.15;
    const pw = CW / phases.length;
    const pc = [C.primary, C.primaryDark, C.navy];
    phases.forEach((ph, i) => {
      const px = ML + i * pw;
      s.addShape("rect", { x: px, y: cy, w: pw - 0.05, h: 0.3, fill: { color: pc[i] || C.primary } });
      s.addText(ph.label, { x: px, y: cy, w: pw - 0.05, h: 0.3, fontSize: 9.5, fontFace: F.header, color: C.white, bold: true, align: "center", valign: "middle", margin: 0 });
      s.addText(ph.title, { x: px + 0.05, y: cy + 0.35, w: pw - 0.15, h: 0.35, fontSize: 11, fontFace: F.header, color: pc[i] || C.primary, bold: true, align: "center", margin: 0 });
      const it = ph.items.map((t, j) => ({ text: t, options: { bullet: true, breakLine: j < ph.items.length - 1, fontSize: 9, fontFace: F.body, color: C.text } }));
      s.addText(it, { x: px + 0.1, y: cy + 0.75, w: pw - 0.2, h: 1.5, margin: [3, 4, 3, 4] });
    });
    const sep = cy + 2.35;
    s.addShape("line", { x: ML, y: sep, w: CW, h: 0, line: { color: C.gray, width: 0.5, dashType: "dash" } });
    (dataRows || []).forEach((row, ri) => {
      const ry = sep + 0.1 + ri * 0.7;
      s.addText(row.label, { x: ML, y: ry, w: 0.95, h: 0.25, fontSize: 9, fontFace: F.header, color: C.primary, bold: true, margin: 0 });
      row.cells.forEach((cell, i) => {
        const cx = ML + i * pw;
        const ci = (Array.isArray(cell) ? cell : [cell]).map((c, j, a) => ({ text: c, options: { bullet: true, breakLine: j < a.length - 1, fontSize: 8.5, fontFace: F.body, color: C.text } }));
        s.addText(ci, { x: cx + 0.05, y: ry + 0.26, w: pw - 0.1, h: 0.5, margin: [2, 4, 2, 4] });
      });
    });
    return s;
  }

  // 左:表 + 右:要点ボックス（▶）
  function factSlide(pres, { title, message = "", headers, rows, colWidths, points, conclusion, pageNum }) {
    const s = contentSlide(pres, { title, message, pageNum });
    const cy = message ? 1.4 : 1.15, tw = 5.5, ix = ML + tw + 0.3, iw = CW - tw - 0.3;
    addTable(s, { headers, rows, x: ML, y: cy, w: tw, h: 3.2, colWidths });
    s.addShape("rect", { x: ix, y: cy - 0.05, w: iw, h: 3.4, line: { color: C.primary, width: 1.5 }, fill: { color: C.white } });
    s.addText("▶", { x: ix + 0.1, y: cy + 0.05, w: iw - 0.2, h: 0.3, fontSize: 11, fontFace: F.header, color: C.primary, bold: true, margin: 0 });
    let yy = cy + 0.4;
    points.forEach(p => { s.addText(p.text, { x: ix + 0.1, y: yy, w: iw - 0.2, h: 0.5, fontSize: 9, fontFace: F.body, color: C.text, bold: !!p.bold, margin: [2, 4, 2, 4] }); yy += 0.55; });
    if (conclusion) s.addText(conclusion, { x: ix + 0.1, y: yy + 0.1, w: iw - 0.2, h: 0.7, fontSize: 9.5, fontFace: F.body, color: C.primary, bold: true, italic: true, margin: [4, 4, 4, 4] });
    return s;
  }

  // ネクストアクション（相手 / 自社 の2カラム）
  function dualNASlide(pres, { title = "ネクストアクション", message = "", nextMeeting, leftLabel = "貴社", left, rightLabel = "弊社", right, pageNum }) {
    const s = contentSlide(pres, { title, message, pageNum });
    const cy = message ? 1.3 : 1.1;
    if (nextMeeting) {
      s.addShape("rect", { x: ML, y: cy, w: CW, h: 0.35, line: { color: C.primary, width: 1 }, fill: { color: C.white } });
      s.addText(nextMeeting, { x: ML + 0.2, y: cy, w: CW - 0.4, h: 0.35, fontSize: 10.5, fontFace: F.body, color: C.text, valign: "middle", margin: 0 });
    }
    const by = cy + 0.5, bw = (CW - 0.2) / 2;
    [[ML, leftLabel, left], [ML + bw + 0.2, rightLabel, right]].forEach(([bx, label, acts]) => {
      s.addShape("line", { x: bx, y: by + 0.15, w: bw, h: 0, line: { color: C.gray, width: 0.5 } });
      s.addText(label, { x: bx + 0.1, y: by, w: 1.2, h: 0.28, fontSize: 11, fontFace: F.header, color: C.primary, bold: true, margin: 0 });
      acts.forEach((a, i) => {
        const ay = by + 0.35 + i * 0.75, num = String.fromCharCode(0x2460 + i);
        s.addText(`${num} ${a.title}`, { x: bx + 0.1, y: ay, w: bw - 0.2, h: 0.28, fontSize: 10.5, fontFace: F.header, color: C.text, bold: true, margin: 0 });
        s.addText(a.detail, { x: bx + 0.3, y: ay + 0.3, w: bw - 0.4, h: 0.4, fontSize: 9, fontFace: F.body, color: C.text, margin: 0 });
      });
    });
    return s;
  }

  return { pptxgen, T, W, H, ML, MR, CW, createPresentation, counter, addLogo, addFooter,
    coverSlide, contentSlide, dividerSlide, addTable, tableSlide, stepFlowSlide, roadmapSlide, factSlide, dualNASlide };
};
```

---

## build_deck.js（生成スケルトン）

```javascript
const path = require("path");
const D = require("./deck_helpers")(require("./theme"));
const { createPresentation, counter, coverSlide, dividerSlide, tableSlide, stepFlowSlide, roadmapSlide, factSlide, dualNASlide } = D;

(async () => {
  const pres = createPresentation("デッキ");
  const pg = counter(); // 表紙=1扱い、本文で pageNum: pg()

  coverSlide(pres, { client: "○○株式会社 御中", phase: "フェーズ名", subtitle: "サブタイトル", date: "2026年X月X日" });
  // contentSlide / tableSlide / stepFlowSlide ... を pageNum: pg() で並べる
  // 区切りは dividerSlide（pg() を呼ばない）

  await pres.writeFile({ fileName: path.join(__dirname, "deck.pptx") });
})().catch(e => { console.error(e); process.exit(1); });
```

生成 → PDF確認：
```bash
node build_deck.js && soffice --headless --convert-to pdf --outdir . deck.pptx
pdftoppm -r 95 -png deck.pdf _preview/p   # 各ページを画像化して目視
```

---

## 運用Tips（このワークフローで効く実務知）

- **PDFで必ず目視確認**してから納品。テーブル溢れ・タイトル折返し・余白崩れはここで初めて見える。
- **タイトルは1行に収める**。長いと水平線にかかる。簡潔化する（幅は contentSlide で 8.6" 確保済み）。
- **テーブルは1枚 ≤ 5行程度**を目安に。多いとセルが溢れて footer を割る。`tableH` で全体高を制御し、フォントは 8.5–9pt。
- **箇条書きのインデント（デフォルト）**：**テキストの前 0.45cm／ぶら下げ 0.4cm**（＝OOXML `marL="162000" indent="-144000"`、1cm=360000 EMU）。これを全箇条書きの既定とする。
  - **PptxGenJS は `bullet.indent` で marL と ぶら下げ(indent)を必ず同値にする**（内部で `marL=bulletMarL, indent=-bulletMarL`）ため、テキスト前(0.45)とぶら下げ(0.4)を別値にはできない。→ **生成後に slide XML を後処理**して厳密値へ置換する：
    ```python
    import sys, zipfile, re, shutil
    def fix(path):  # 箇条書き段落のみ: PptxGenJSは `marL="N" indent="-N"`(marL先頭・等値) のみ出力。
        pat=re.compile(r'marL="(\d+)" indent="-\1"'); repl='marL="162000" indent="-144000"'; tmp=path+'.tmp'
        with zipfile.ZipFile(path) as zin, zipfile.ZipFile(tmp,'w',zipfile.ZIP_DEFLATED) as zout:
            for it in zin.infolist():
                d=zin.read(it.filename)
                if it.filename.startswith('ppt/slides/slide') and it.filename.endswith('.xml'):
                    d=pat.subn(repl, d.decode('utf-8'))[0].encode('utf-8')
                zout.writestr(it, d)
        shutil.move(tmp, path)
    fix(sys.argv[1])
    ```
    非箇条書きは `indent="0" marL="0"`（順序が逆）、表セルは `<a:tcPr ... marL=...>`（indent無し）なので、この正規表現は箇条書き段落だけに一致して安全。`inject_theme` の後（PDF化の前）に1回流す。実例: `~/workspace/sysmex/notes/slides/build/fix_bullet_indent.py`。
- **ページ番号は手で振らない**。`pg()` カウンタで採番すれば、スライドの挿入・並び替え後も自動で整う。
- **区切り・表紙は採番しない**（`pg()` を呼ばない）。
- **強調は色の濃淡で**：通常ノード=primary、主役ノード=navy（`step.accent: C.navy`）。
- **図解は原則 PptxGenJS のネイティブ図形で作る（編集可能性を最優先）**。納品先（PowerPoint/Google Slides）で箱の移動・文言修正・色変更が直接できることが重要。`roundRect`＋`addText`、`line`（`endArrowType:'triangle'`/`beginArrowType` で矢印、`dashType:'dash'` で点線）で構成図・責任分界・A/B案程度なら十分きれいに作れる。画像（PNG/SVG→addImage）は最後の手段。
  - **drawio → ネイティブ移植フロー**（中〜やや複雑な図はこれが効く。「設計は drawio、再現は PPTX」）：
    1. **提案・設計は drawio** で行う（編集しやすく、ユーザーにレビューしてもらう設計の正本）。`drawio -x -f png --scale 3 --border 10 -o fig.png fig.drawio` でプレビュー化（drawio CLI 未導入環境では `.deb` を `dpkg-deb -x` でユーザー空間展開＋`xvfb-run` ラッパーで入る。sudo不要）。
    2. 承認後、**drawio の px 座標・配色をそのまま PptxGenJS のネイティブ図形へ移植**して再現。px→inch を等倍変換する小ヘルパーを噛ませると座標を機械的に移せる：
       ```js
       function diagramDrawer(slide, {ox, oy, w, Wpx, fontk=1.45}){  // ox,oy,w=inch / Wpx=drawioキャンバス幅px
         const s=w/Wpx, X=p=>ox+p*s, Y=p=>oy+p*s, IN=p=>p*s, PT=p=>Math.round(p*s*72*fontk*10)/10;
         const box=(px,py,pw,ph,t,fill,fc,fpx,o={})=>{ slide.addShape('roundRect',{x:X(px),y:Y(py),w:IN(pw),h:IN(ph),fill:{color:fill},line:o.stroke?{color:o.stroke,width:1}:{type:'none'},rectRadius:0.04});
           slide.addText(t,{x:X(px),y:Y(py),w:IN(pw),h:IN(ph),color:fc,fontFace:FONTS.header,fontSize:PT(fpx),bold:true,align:o.align||'center',valign:'middle',lineSpacingMultiple:0.95}); };
         const arrow=(x1,y1,x2,y2,c,wpx)=>{ const lw=Math.max(1.5,IN(wpx)*72);
           x2>=x1 ? slide.addShape('line',{x:X(x1),y:Y(y1),w:IN(x2-x1),h:IN(y2-y1),line:{color:c,width:lw,endArrowType:'triangle'}})
                  : slide.addShape('line',{x:X(x2),y:Y(y2),w:IN(x1-x2),h:IN(y1-y2),line:{color:c,width:lw,beginArrowType:'triangle'}}); };
         return {box, arrow /* container/txt/dline も同様 */};
       }
       ```
       `fontk` は px→pt が小さくなりがちなので 1.4〜1.5 で読みやすさを補正（箱からの溢れは PDF 目視で調整）。図スライドは説明文を省いて図に全幅を使うと収まりやすい。
    3. **deck本体に drawio の PNG は埋め込まない**（編集できなくなるため）。`.drawio` は設計アーティファクトとして残す。
  - 実例: シスメックス案件 `~/workspace/sysmex/notes/slides/`（`build/gen_diagrams.py`=drawio生成、`build/gen_deck.js` の `drawSystemArchitecture`/`drawResponsibility`/`drawDataDeletion`=ネイティブ移植）。
- **直接編集された pptx の取り込み**：pptx を解凍し `ppt/presentation.xml` の `sldIdLst` で順序、各 `slideN.xml` の `<a:off>/<a:ext>`(EMU÷914400=inch) で図形座標、`<a:t>` でテキストを抽出 → 生成スクリプト（正本）へ反映。順序・座標・テキストは確実に差分が取れる（書式の微調整は取りこぼしうる）。
- **正本は build_deck.js**。直接編集した pptx は再生成で上書きされるため、必ずスクリプトへ取り込む。
