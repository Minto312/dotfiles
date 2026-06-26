// raim_helpers.js — Raim Technologies コーポレート・スライド用 theme 駆動ヘルパー
//
// 設計方針:
//   - 色・フォントは すべて theme.js から引く（色コードの直書き禁止）
//   - レイアウトは slidecraft の「良いスライドの原則」を踏襲（1スライド1メッセージ、
//     タイトル2層、So-What を ▶ で示す、ページ自動採番）
//   - 見た目は raim_intro_v4 のコンサル風（章番号タグ・Exhibit カード・上品な緑アクセント）を再現
//
// 使い方:
//   const D = require("./raim_helpers")(require("./theme"));
//   D.setDeck({ title: "会社案内（採用・パートナー向け）" });   // 本文ヘッダ右上に出る通し名
//   const pres = D.createPresentation("Raim 会社案内");
//   const pg = D.counter();
//   D.coverSlide(pres, {...});
//   D.execSummarySlide(pres, { ..., pageNum: pg() });
//   await pres.writeFile({ fileName: "out.pptx" });

const pptxgen = require("pptxgenjs");
const { execSync } = require("child_process");
const fs = require("fs");
const JSZip = require("jszip"); // pptxgenjs の依存。生成後にレイアウトへページ番号を焼き込む後処理で使用

module.exports = function (T) {
  // ── フォント・フォールバック（Yu Gothic UI 無ければ Meiryo UI → Noto Sans CJK JP）──
  // 解決結果はローカル F に持ち、引数 theme は書き換えない（同一プロセスで複数ブランドを使っても漏れない）
  const hasFont = (name) => {
    try { execSync(`fc-list | grep -i "${name}"`, { stdio: "ignore" }); return true; }
    catch { return false; } // fc-list が無い環境では false（→ Noto に倒れる）
  };
  const resolveFont = (name) => hasFont(name) ? name : (hasFont("Meiryo UI") ? "Meiryo UI" : "Noto Sans CJK JP");
  const headerFont = resolveFont(T.fonts.header);
  const F = {
    header:  headerFont,
    body:    resolveFont(T.fonts.body),
    tagline: hasFont(T.fonts.tagline) ? T.fonts.tagline : headerFont,
  };

  const C = T.colors, L = T.logo;
  const W = 10, H = 5.625, ML = 0.5, MR = 0.5, CW = W - ML - MR; // 9.0
  const BODY_BOTTOM = 4.92; // 本文セーフエリア下端（フッター y=H-0.34 と整合。各レイアウトはここを基準に高さ算出）

  // 本文ヘッダ右上の通し名。※1プロセス=1デッキ前提（バッチ生成では各 build を別プロセスで）
  let DECK = { title: "" };
  const setDeck = (o) => Object.assign(DECK, o);

  // ── 小ユーティリティ ──
  // "**強調**" を含む文字列を addText 用の run 配列に変換
  function parseBold(str) {
    return String(str).split(/\*\*(.+?)\*\*/g)
      .map((p, i) => ({ text: p, options: i % 2 ? { bold: true } : {} }))
      .filter((r) => r.text !== "");
  }
  const dash = (color) => ({ text: "—  ", options: { color: color || C.primary, bold: true } });

  // 本文スライド用マスター "RAIM_BODY"。共通フッター（罫線・TLP・©）とヘッダ罫線、
  // そして PowerPoint ネイティブのページ番号フィールド（<a:fld type="slidenum">）を乗せる。
  // → 生成後に PowerPoint でスライドを挿入・削除・並べ替えしても、番号が自動で振り直される（手作業不要）。
  // 全スライド種をスライドマスター/レイアウト化する。
  //   - 繰り返し固定要素（帯・ロゴ・会社情報・フッター・罫線）→ objects（通常図形）
  //   - 可変テキスト（タイトル・章番号・リード文など）→ placeholder
  // → PowerPoint でどのレイアウトを選んでも、ブランド要素が自動で付く／入力枠が出る／アウトラインに載る。
  function defineMasters(p) {
    const fy = H - 0.34;
    const aspH = (w) => w / (L.aspect || 2.9);       // 横ロゴの高さ
    const symH = (w) => w / (L.symbolAspect || 0.835); // シンボルの高さ

    // ── RAIM_BODY（本文）──
    const body = [
      { line: { x: ML, y: 0.9, w: CW, h: 0, line: { color: C.primary, width: 0.75 } } },      // ヘッダ罫線
      { line: { x: ML, y: fy - 0.06, w: CW, h: 0, line: { color: C.border, width: 0.5 } } },  // フッター罫線
      { text: { text: T.company.copyright, options: { x: 0, y: fy, w: W, h: 0.22, fontSize: 7.5, fontFace: F.tagline, color: C.copyright, align: "center", valign: "middle", margin: 0 } } },
    ];
    if (T.confidentialLabel) body.push({ text: { text: T.confidentialLabel, options: { x: ML, y: fy, w: 2.4, h: 0.22, fontSize: 7.5, fontFace: F.header, color: C.primaryDark, bold: true, valign: "middle", margin: 0 } } });
    if (DECK.title) body.push({ text: { text: DECK.title, options: { x: 5.0, y: 0.45, w: 4.5, h: 0.3, fontSize: 9, fontFace: F.body, color: C.textGray, align: "right", valign: "middle", margin: 0 } } });
    body.push({ placeholder: { options: { name: "slideNo", type: "body", x: ML, y: 0.42, w: 0.46, h: 0.34, fontFace: F.header, fontSize: 13, color: C.white, bold: true, align: "center", valign: "middle", fill: { color: C.primary }, margin: 0 }, text: "01" } });
    body.push({ placeholder: { options: { name: "slideTitle", type: "title", x: ML + 0.58, y: 0.42, w: 3.6, h: 0.34, fontFace: F.header, fontSize: 13, color: C.text, bold: true, align: "left", valign: "middle", margin: 0 }, text: "スライドタイトル" } });
    body.push({ placeholder: { options: { name: "leadText", type: "body", x: ML, y: 1.04, w: CW, h: 0.5, fontFace: F.header, fontSize: 14, color: C.text, bold: true, align: "left", valign: "top", margin: 0 }, text: "リード文（このスライドの結論を1行で）" } });
    p.defineSlideMaster({ title: "RAIM_BODY", background: { color: C.white }, objects: body });
    // ページ番号(slidenum)は writeDeck() の後処理で RAIM_BODY レイアウトに通常図形として焼き込む。

    // ── RAIM_COVER（表紙）──
    p.defineSlideMaster({
      title: "RAIM_COVER",
      background: { color: C.white },
      objects: [
        { rect: { x: 7.7, y: 0, w: 2.3, h: H, fill: { color: C.primaryDark } } },          // 右濃緑帯
        { rect: { x: 7.56, y: 0, w: 0.12, h: H, fill: { color: C.primary } } },            // 内側ストライプ
        { image: { path: L.symbolLight, x: 8.55, y: 3.85, w: 0.85, h: symH(0.85) } },      // 帯上の白シンボル
        { image: { path: L.dark, x: 0.55, y: 0.6, w: 2.5, h: aspH(2.5) } },                // ロゴ
        { rect: { x: 0.62, y: 3.72, w: 0.95, h: 0.07, fill: { color: C.primary } } },      // 緑アクセント下線
        { text: { text: T.company.nameEn, options: { x: 0.6, y: 5.12, w: 4, h: 0.25, fontSize: 9, fontFace: F.tagline, color: C.textGray, valign: "middle", margin: 0 } } },
        { placeholder: { options: { name: "coverTitle", type: "title", x: 0.6, y: 2.1, w: 6.7, h: 1.5, fontFace: F.header, fontSize: 26, color: C.text, bold: true, valign: "top", lineSpacingMultiple: 1.02, margin: 0 }, text: "タイトル" } },
        { placeholder: { options: { name: "coverSubtitle", type: "body", x: 0.6, y: 3.95, w: 6.7, h: 0.4, fontFace: F.header, fontSize: 15, color: C.text, bold: true, valign: "top", margin: 0 }, text: "サブタイトル" } },
        { placeholder: { options: { name: "coverMeta", type: "body", x: 0.6, y: 4.45, w: 6.7, h: 0.3, fontFace: F.body, fontSize: 12, color: C.textGray, valign: "top", margin: 0 }, text: "対象 / 日付" } },
        { placeholder: { options: { name: "coverConf", type: "body", x: 4.8, y: 5.12, w: 2.5, h: 0.25, fontFace: F.header, fontSize: 8, color: C.primaryDark, bold: true, align: "right", valign: "middle", margin: 0 }, text: T.confidentialLabel || "TLP:AMBER" } },
      ],
    });

    // ── RAIM_DIVIDER（章扉）──
    p.defineSlideMaster({
      title: "RAIM_DIVIDER",
      background: { color: C.primaryDark },
      objects: [
        { rect: { x: 0, y: 0, w: 0.18, h: H, fill: { color: C.primary } } },               // 左緑帯
        { image: { path: L.light, x: 0.55, y: 0.5, w: 1.9, h: aspH(1.9) } },               // 白ロゴ
        { rect: { x: 0.62, y: 2.82, w: 1.1, h: 0.06, fill: { color: C.primary } } },        // 緑下線
        { text: { text: T.company.copyright, options: { x: 0, y: fy, w: W, h: 0.22, fontSize: 7.5, fontFace: F.tagline, color: C.footerOnDark, align: "center", valign: "middle", margin: 0 } } },
        ...(T.confidentialLabel ? [{ text: { text: T.confidentialLabel, options: { x: ML, y: fy, w: 2.4, h: 0.22, fontSize: 7.5, fontFace: F.header, color: C.white, bold: true, valign: "middle", margin: 0 } } }] : []),
        { placeholder: { options: { name: "divNo", type: "body", x: 0.6, y: 1.85, w: 3, h: 1.0, fontFace: F.header, fontSize: 54, color: C.primaryLight, bold: true, valign: "top", margin: 0 }, text: "01" } },
        { placeholder: { options: { name: "divTitle", type: "title", x: 0.6, y: 2.95, w: 8.8, h: 1.2, fontFace: F.header, fontSize: 30, color: C.white, bold: true, valign: "top", lineSpacingMultiple: 1.0, margin: 0 }, text: "章タイトル" } },
      ],
    });

    // ── RAIM_CLOSING（裏表紙）──
    const co = T.company;
    p.defineSlideMaster({
      title: "RAIM_CLOSING",
      background: { color: C.primaryDark },
      objects: [
        { rect: { x: 0, y: 0, w: W, h: 0.18, fill: { color: C.primary } } },               // 上緑帯
        { rect: { x: 0, y: H - 0.18, w: W, h: 0.18, fill: { color: C.primary } } },         // 下緑帯
        { image: { path: L.light, x: (W - 3.0) / 2, y: 1.35, w: 3.0, h: aspH(3.0) } },      // 白ロゴ（中央）
        { text: { text: [co.nameJa, co.hq, `代表者：${co.ceo}　設立：${co.founded}`, `${co.url}　${co.email}`].join("\n"), options: { x: 0, y: 3.55, w: W, h: 1.4, fontSize: 10.5, fontFace: F.body, color: C.white, align: "center", valign: "top", lineSpacingMultiple: 1.35, margin: 0 } } },
        { placeholder: { options: { name: "closeMsg", type: "title", x: 0, y: 2.7, w: W, h: 0.6, fontFace: F.header, fontSize: 26, color: C.white, bold: true, align: "center", valign: "middle", margin: 0 }, text: "Thank you" } },
      ],
    });
  }

  function createPresentation(title) {
    const p = new pptxgen();
    p.layout = "LAYOUT_16x9";
    p.title = title || T.company.nameJa;
    p.author = T.company.nameJa;
    defineMasters(p);
    return p;
  }
  // 後方互換用の手動カウンタ（現在は本文のページ番号をマスターのネイティブ番号で出すため通常は不要）
  function counter() { let n = 1; return () => ++n; }

  function addLogo(slide, variant, opt) {
    const o = opt || {};
    const img = variant === "light" ? L.light : L.dark;
    const w = o.w != null ? o.w : 2.0;
    const h = w / (L.aspect || 2.9);
    slide.addImage({ path: img, x: o.x != null ? o.x : 0.55, y: o.y != null ? o.y : 0.5, w, h });
  }

  // フッター（variant: "dark"=白地 / "light"=濃緑地）
  function addFooter(slide, opt) {
    const o = opt || {};
    const onDark = o.variant === "light";
    const fy = H - 0.34;
    if (!onDark) slide.addShape("line", { x: ML, y: fy - 0.06, w: CW, h: 0, line: { color: C.border, width: 0.5 } });
    const label = o.conf !== undefined ? o.conf : T.confidentialLabel;
    if (label) slide.addText(label, { x: ML, y: fy, w: 2.4, h: 0.22, fontSize: 7.5, fontFace: F.header, color: onDark ? C.white : C.primaryDark, bold: true, valign: "middle", margin: 0 });
    slide.addText(`© ${T.year} ${T.company.nameJa}`, { x: 0, y: fy, w: W, h: 0.22, fontSize: 7.5, fontFace: F.tagline, color: onDark ? C.footerOnDark : C.copyright, align: "center", valign: "middle", margin: 0 });
    if (o.pageNum) slide.addText(String(o.pageNum), { x: W - MR - 0.4, y: fy, w: 0.4, h: 0.22, fontSize: 9, fontFace: F.tagline, color: onDark ? C.white : C.textGray, align: "right", valign: "middle", margin: 0 });
  }

  // ── 本文共通ヘッダ（章番号タグ + セクション名 + 右上デッキ名）──
  // 背景・ヘッダ罫線・フッター・ページ番号は "RAIM_BODY" マスター由来（ここでは描かない）
  function contentSlide(pres, opt) {
    const o = opt || {};
    const s = pres.addSlide({ masterName: "RAIM_BODY" });
    if (o.sectionNo) s.addText(o.sectionNo, { placeholder: "slideNo" });        // 緑タグ＋番号（背景はプレースホルダの塗り）
    if (o.sectionName) s.addText(o.sectionName, { placeholder: "slideTitle" }); // 位置・書式はレイアウトの title プレースホルダ由来
    // 右上デッキ名・ページ番号・フッターは RAIM_BODY レイアウト由来（新規スライドにも継承される）
    return s;
  }

  // タイトル2層（テーマ + 濃緑 takeaway 帯）。content 開始 Y を返す
  function addTitleBlock(s, opt) {
    const o = opt || {};
    // リード文は leadText プレースホルダ（位置 y=1.04・書式はレイアウト由来）に流し込む
    let y = 1.04;
    if (o.title) {
      s.addText(o.title, { placeholder: "leadText" });
      y += 0.55; // リード文枠(固定高)の分だけ送る
    }
    if (o.takeaway) {
      s.addShape("rect", { x: ML, y, w: CW, h: 0.42, fill: { color: C.primaryDark } });
      s.addText(o.takeaway, { x: ML + 0.15, y, w: CW - 0.3, h: 0.42, fontSize: 11, fontFace: F.header, color: C.white, bold: true, valign: "middle", margin: 0 });
      y += 0.54;
    }
    return y;
  }

  // Exhibit カード（図版・データ挿入枠）
  function addExhibit(s, o) {
    s.addShape("rect", { x: o.x, y: o.y, w: o.w, h: o.h, fill: { color: C.white }, line: { color: C.border, width: 0.75 } });
    s.addShape("rect", { x: o.x, y: o.y, w: o.w, h: 0.04, fill: { color: C.primary } });
    s.addText(o.label || "EXHIBIT", { x: o.x + 0.12, y: o.y + 0.1, w: o.w - 0.24, h: 0.2, fontSize: 8, fontFace: F.header, color: C.primary, bold: true, charSpacing: 1, margin: 0 });
    s.addText(o.title, { x: o.x + 0.12, y: o.y + 0.32, w: o.w - 0.24, h: 0.5, fontSize: 10, fontFace: F.header, color: C.text, bold: true, valign: "top", lineSpacingMultiple: 0.95, margin: 0 });
    s.addText("［図版・データ挿入エリア］", { x: o.x + 0.12, y: o.y + o.h - 0.52, w: o.w - 0.24, h: 0.24, fontSize: 8.5, fontFace: F.body, color: C.gray, align: "center", valign: "middle", margin: 0 });
    if (o.source) s.addText("Source: " + o.source, { x: o.x + 0.12, y: o.y + o.h - 0.26, w: o.w - 0.24, h: 0.2, fontSize: 7, fontFace: F.body, color: C.textGray, italic: true, margin: 0 });
  }

  // 番号付きカード（MECE）
  function addCard(s, o) {
    s.addShape("rect", { x: o.x, y: o.y, w: o.w, h: 0.42, fill: { color: C.primaryDark } });
    if (o.no) {
      s.addShape("rect", { x: o.x, y: o.y, w: 0.42, h: 0.42, fill: { color: C.primary } });
      s.addText(o.no, { x: o.x, y: o.y, w: 0.42, h: 0.42, fontSize: 12, fontFace: F.header, color: C.white, bold: true, align: "center", valign: "middle", margin: 0 });
    }
    s.addText(o.heading, { x: o.x + (o.no ? 0.5 : 0.12), y: o.y, w: o.w - (o.no ? 0.6 : 0.24), h: 0.42, fontSize: 11, fontFace: F.header, color: C.white, bold: true, valign: "middle", margin: 0 });
    s.addShape("rect", { x: o.x, y: o.y + 0.42, w: o.w, h: o.h - 0.42, fill: { color: C.white }, line: { color: C.border, width: 0.75 } });
    s.addText(parseBold(o.body), { x: o.x + 0.12, y: o.y + 0.52, w: o.w - 0.24, h: o.h - 0.6, fontSize: 9.5, fontFace: F.body, color: C.text, valign: "top", lineSpacingMultiple: 1.0, fit: "shrink", margin: 0 });
  }

  // 汎用テーブル（ヘッダ濃緑、偶奇縞）
  function addTable(slide, o) {
    const headers = o.headers, rows = o.rows;
    const x = o.x != null ? o.x : ML, y = o.y != null ? o.y : 1.5, w = o.w != null ? o.w : CW;
    const hr = headers.map((t) => ({ text: t, options: { fill: { color: C.primaryDark }, color: C.white, bold: true, fontSize: 10, fontFace: F.header, align: "center", valign: "middle" } }));
    const dr = rows.map((row, ri) => row.map((cell) => {
      const base = { fill: { color: ri % 2 ? C.lightGray : C.white }, color: C.text, fontSize: 9.5, fontFace: F.body, valign: "middle", margin: [3, 5, 3, 5] };
      return (cell && typeof cell === "object" && "text" in cell)
        ? { text: cell.text, options: Object.assign(base, cell.options || {}) }
        : { text: String(cell), options: base };
    }));
    const tot = o.colWidths ? o.colWidths.reduce((a, b) => a + b, 0) : headers.length;
    const cw = o.colWidths ? o.colWidths.map((c) => c / tot * w) : headers.map(() => w / headers.length);
    const rh = o.h ? [0.4, ...rows.map(() => (o.h - 0.4) / rows.length)] : [0.4, ...rows.map(() => 0.55)];
    // autoPage:false … 行が溢れても勝手に次スライドへ送らない（溢れたら呼び出し側で分割する運用）
    slide.addTable([hr, ...dr], { x, y, w, colW: cw, border: { pt: 0.5, color: C.border }, rowH: rh, autoPage: false });
  }

  // ============================================================
  //  レイアウト関数（フルセット）
  // ============================================================

  // 1) 表紙（RAIM_COVER マスター：帯・ロゴ・下線・社名は固定、タイトル類はプレースホルダ）
  function coverSlide(pres, o) {
    const s = pres.addSlide({ masterName: "RAIM_COVER" });
    s.addText(o.bigTitle, { placeholder: "coverTitle" });
    if (o.subtitle) s.addText(o.subtitle, { placeholder: "coverSubtitle" });
    const meta = [o.audience, o.date].filter(Boolean).join("　/　");
    if (meta) s.addText(meta, { placeholder: "coverMeta" });
    const conf = o.confidentiality !== undefined ? o.confidentiality : T.confidentialLabel;
    if (conf) s.addText(conf, { placeholder: "coverConf" });
    return s;
  }

  // 2) 目次 / アジェンダ
  function agendaSlide(pres, o) {
    const s = contentSlide(pres, { sectionName: "Agenda", pageNum: o.pageNum });
    s.addText(o.title || "本日お話しすること", { placeholder: "leadText" });
    const items = o.items || [];
    const y0 = 1.85, gap = Math.min(0.72, (4.85 - y0) / Math.max(items.length, 1));
    items.forEach((it, i) => {
      const y = y0 + i * gap;
      s.addShape("rect", { x: ML, y, w: 0.5, h: 0.42, fill: { color: C.primary } });
      s.addText(it.no || String(i + 1).padStart(2, "0"), { x: ML, y, w: 0.5, h: 0.42, fontSize: 14, fontFace: F.header, color: C.white, bold: true, align: "center", valign: "middle", margin: 0 });
      s.addText(it.name, { x: ML + 0.7, y, w: CW - 0.7, h: 0.42, fontSize: 14, fontFace: F.header, color: C.text, bold: true, valign: "middle", margin: 0 });
      s.addShape("line", { x: ML + 0.7, y: y + 0.47, w: CW - 0.7, h: 0, line: { color: C.border, width: 0.5 } });
    });
    return s;
  }

  // 3) 章扉（RAIM_DIVIDER マスター：背景・左緑帯・白ロゴ・下線・フッターは固定、番号/章名はプレースホルダ）
  function dividerSlide(pres, o) {
    const s = pres.addSlide({ masterName: "RAIM_DIVIDER" });
    if (o.sectionNo) s.addText(o.sectionNo, { placeholder: "divNo" });
    s.addText(o.title, { placeholder: "divTitle" });
    return s;
  }

  // 4) 箇条書き本文
  function bulletSlide(pres, o) {
    const s = contentSlide(pres, { sectionNo: o.sectionNo, sectionName: o.sectionName, pageNum: o.pageNum });
    const cy = addTitleBlock(s, { title: o.title, takeaway: o.takeaway });
    (o.bullets || []).forEach((b, i) => {
      s.addText([dash(), ...parseBold(b)], { x: ML + 0.1, y: cy + 0.1 + i * 0.55, w: CW - 0.2, h: 0.55, fontSize: 12, fontFace: F.body, color: C.text, valign: "top", lineSpacingMultiple: 1.02, fit: "shrink", margin: 0 });
    });
    return s;
  }

  // 5) エグゼクティブサマリ 1pager（箇条書き + Exhibit×3 + Decide/Next）
  function execSummarySlide(pres, o) {
    const s = contentSlide(pres, { sectionNo: o.sectionNo, sectionName: o.sectionName, pageNum: o.pageNum });
    const cy = addTitleBlock(s, { title: o.title, takeaway: o.takeaway });
    const nb = (o.bullets || []).length;
    (o.bullets || []).forEach((b, i) => {
      s.addText([dash(), ...parseBold(b)], { x: ML + 0.1, y: cy + 0.05 + i * 0.32, w: CW - 0.2, h: 0.32, fontSize: 10.5, fontFace: F.body, color: C.text, valign: "top", margin: 0 });
    });
    const ex = o.exhibits || [];
    if (ex.length) {
      const exy = Math.max(3.2, cy + 0.05 + nb * 0.32 + 0.15); // 箇条書きの下端に追従させ重なりを防ぐ
      const gap = 0.25, w = (CW - (ex.length - 1) * gap) / ex.length, h = Math.max(0.9, BODY_BOTTOM - 0.2 - exy);
      ex.forEach((e, i) => addExhibit(s, { x: ML + i * (w + gap), y: exy, w, h, label: e.label, title: e.title, source: e.source }));
    }
    const dy = 4.82;
    if (o.decide) s.addText([{ text: "▶ Decide：", options: { bold: true, color: C.primaryDark } }, ...parseBold(o.decide)], { x: ML, y: dy, w: CW / 2 - 0.1, h: 0.3, fontSize: 9.5, fontFace: F.body, color: C.text, valign: "middle", margin: 0 });
    if (o.next) s.addText([{ text: "▶ Next：", options: { bold: true, color: C.primaryDark } }, ...parseBold(o.next)], { x: ML + CW / 2 + 0.1, y: dy, w: CW / 2 - 0.1, h: 0.3, fontSize: 9.5, fontFace: F.body, color: C.text, valign: "middle", margin: 0 });
    return s;
  }

  // 6) MECE カード（3〜5枚）
  function meceCardsSlide(pres, o) {
    const s = contentSlide(pres, { sectionNo: o.sectionNo, sectionName: o.sectionName, pageNum: o.pageNum });
    let cy = addTitleBlock(s, { title: o.title });
    if (o.sub) { s.addText(o.sub, { x: ML, y: cy - 0.05, w: CW, h: 0.35, fontSize: 11, fontFace: F.body, color: C.textGray, margin: 0 }); cy += 0.42; }
    const cards = o.cards || [];
    const n = cards.length;
    const cols = n <= 3 ? n : 2;
    const rows = Math.ceil(n / cols);
    const gap = 0.25;
    const areaY = cy + 0.05;
    const areaBottom = o.summary ? BODY_BOTTOM - 0.37 : BODY_BOTTOM;
    const ch = (areaBottom - areaY - (rows - 1) * gap) / rows;
    const cw = (CW - (cols - 1) * gap) / cols;
    cards.forEach((c, i) => {
      const r = Math.floor(i / cols), col = i % cols;
      const inRow = Math.min(cols, n - r * cols);
      const rowW = inRow * cw + (inRow - 1) * gap;
      const offset = (CW - rowW) / 2;
      const x = ML + offset + col * (cw + gap);
      const y = areaY + r * (ch + gap);
      addCard(s, { x, y, w: cw, h: ch, no: c.no, heading: c.heading, body: c.body });
    });
    if (o.summary) {
      const sy = 4.62;
      s.addShape("rect", { x: ML, y: sy, w: CW, h: 0.5, fill: { color: C.panelBg }, line: { color: C.primary, width: 1 } });
      s.addText([{ text: "▶  ", options: { bold: true, color: C.primaryDark } }, ...parseBold(o.summary)], { x: ML + 0.15, y: sy, w: CW - 0.3, h: 0.5, fontSize: 10, fontFace: F.body, color: C.text, valign: "middle", margin: 0 });
    }
    return s;
  }

  // 7) ピラミッド（結論 → 根拠3 → 事実 Exhibit）
  function pyramidSlide(pres, o) {
    const s = contentSlide(pres, { sectionNo: o.sectionNo, sectionName: o.sectionName, pageNum: o.pageNum });
    let cy = addTitleBlock(s, { title: o.title });
    s.addShape("rect", { x: ML, y: cy, w: CW, h: 0.55, fill: { color: C.primaryDark } });
    s.addText([{ text: "結論　", options: { bold: true, color: C.primaryLight } }, ...parseBold(o.conclusion).map((r) => ({ text: r.text, options: { ...r.options, color: C.white } }))], { x: ML + 0.15, y: cy, w: CW - 0.3, h: 0.55, fontSize: 11.5, fontFace: F.header, color: C.white, bold: true, valign: "middle", margin: 0 });
    cy += 0.68;
    const sup = o.supports || [];
    const gap = 0.25, w = (CW - (sup.length - 1) * gap) / Math.max(sup.length, 1), h = 1.05;
    sup.forEach((sp, i) => {
      const x = ML + i * (w + gap);
      s.addShape("rect", { x, y: cy, w, h, fill: { color: C.panelBg }, line: { color: C.border, width: 0.75 } });
      s.addText(parseBold(sp), { x: x + 0.12, y: cy + 0.1, w: w - 0.24, h: h - 0.2, fontSize: 10, fontFace: F.body, color: C.text, valign: "top", lineSpacingMultiple: 1.0, fit: "shrink", margin: 0 });
    });
    cy += h + 0.18;
    const fx = o.facts || [];
    if (fx.length) {
      const w2 = (CW - (fx.length - 1) * 0.25) / fx.length, h2 = BODY_BOTTOM - cy;
      fx.forEach((e, i) => addExhibit(s, { x: ML + i * (w2 + 0.25), y: cy, w: w2, h: h2, label: e.label, title: e.title, source: e.source }));
    }
    return s;
  }

  // 8) 数値ハイライト（KPI 3〜4 個）
  function numbersSlide(pres, o) {
    const s = contentSlide(pres, { sectionNo: o.sectionNo, sectionName: o.sectionName, pageNum: o.pageNum });
    const cy = addTitleBlock(s, { title: o.title, takeaway: o.takeaway });
    const m = o.metrics || [];
    if (!m.length) return s;
    const n = m.length, gap = 0.3, w = (CW - (n - 1) * gap) / Math.max(n, 1);
    const y = cy + 0.25, h = BODY_BOTTOM - y;
    m.forEach((mm, i) => {
      const x = ML + i * (w + gap);
      s.addShape("rect", { x, y, w, h, fill: { color: C.panelBg }, line: { color: C.border, width: 0.5 } });
      s.addShape("rect", { x, y, w, h: 0.06, fill: { color: C.primary } });
      s.addText([{ text: mm.value, options: { fontSize: 36, bold: true, color: C.primaryDark } }, { text: mm.unit ? (" " + mm.unit) : "", options: { fontSize: 14, bold: true, color: C.primaryDark } }], { x: x + 0.1, y: y + 0.3, w: w - 0.2, h: 0.95, fontFace: F.header, align: "center", valign: "middle", margin: 0 });
      s.addText(mm.label, { x: x + 0.12, y: y + 1.3, w: w - 0.24, h: 0.4, fontSize: 11, fontFace: F.header, color: C.text, bold: true, align: "center", valign: "top", margin: 0 });
      if (mm.note) s.addText(mm.note, { x: x + 0.12, y: y + h - 0.75, w: w - 0.24, h: 0.65, fontSize: 8.5, fontFace: F.body, color: C.textGray, align: "center", valign: "top", lineSpacingMultiple: 1.0, margin: 0 });
    });
    return s;
  }

  // 9) 比較（2カラム）
  function comparisonSlide(pres, o) {
    const s = contentSlide(pres, { sectionNo: o.sectionNo, sectionName: o.sectionName, pageNum: o.pageNum });
    let cy = addTitleBlock(s, { title: o.title });
    if (o.sub) { s.addText(o.sub, { x: ML, y: cy - 0.05, w: CW, h: 0.35, fontSize: 11, fontFace: F.body, color: C.textGray, margin: 0 }); cy += 0.4; }
    const gap = 0.3, w = (CW - gap) / 2, y = cy + 0.05, h = BODY_BOTTOM - y;
    [[ML, o.left, C.primaryDark], [ML + w + gap, o.right, C.navy]].forEach(([x, col, hc]) => {
      s.addShape("rect", { x, y, w, h: 0.5, fill: { color: hc } });
      s.addText(col.label, { x: x + 0.15, y, w: w - 0.3, h: 0.5, fontSize: 13, fontFace: F.header, color: C.white, bold: true, valign: "middle", margin: 0 });
      s.addShape("rect", { x, y: y + 0.5, w, h: h - 0.5, fill: { color: C.white }, line: { color: C.border, width: 0.75 } });
      (col.points || []).forEach((p, i) => {
        s.addText([dash(hc), ...parseBold(p)], { x: x + 0.15, y: y + 0.65 + i * 0.6, w: w - 0.3, h: 0.6, fontSize: 10.5, fontFace: F.body, color: C.text, valign: "top", lineSpacingMultiple: 1.0, fit: "shrink", margin: 0 });
      });
    });
    return s;
  }

  // 10) タイムライン / ロードマップ
  function timelineSlide(pres, o) {
    const s = contentSlide(pres, { sectionNo: o.sectionNo, sectionName: o.sectionName, pageNum: o.pageNum });
    let cy = addTitleBlock(s, { title: o.title });
    if (o.sub) { s.addText(o.sub, { x: ML, y: cy - 0.05, w: CW, h: 0.35, fontSize: 11, fontFace: F.body, color: C.textGray, margin: 0 }); cy += 0.45; }
    const ph = o.phases || [];
    if (!ph.length) return s;
    const n = ph.length, gap = 0.2, w = (CW - (n - 1) * gap) / Math.max(n, 1), y = cy + 0.1;
    const pc = [C.primary, C.primaryDark, C.navy, C.navy];
    ph.forEach((p, i) => {
      const x = ML + i * (w + gap), col = pc[i] || C.primaryDark;
      s.addShape("rect", { x, y, w, h: 0.4, fill: { color: col } });
      s.addText(p.label, { x, y, w, h: 0.4, fontSize: 11, fontFace: F.header, color: C.white, bold: true, align: "center", valign: "middle", margin: 0 });
      if (p.title) s.addText(p.title, { x: x + 0.05, y: y + 0.46, w: w - 0.1, h: 0.45, fontSize: 11, fontFace: F.header, color: col, bold: true, align: "center", valign: "top", lineSpacingMultiple: 0.95, margin: 0 });
      const iy = y + (p.title ? 0.98 : 0.5);
      (p.items || []).forEach((it, j) => {
        s.addText([{ text: "・", options: { color: col } }, ...parseBold(it)], { x: x + 0.08, y: iy + j * 0.5, w: w - 0.16, h: 0.5, fontSize: 9.5, fontFace: F.body, color: C.text, valign: "top", lineSpacingMultiple: 0.98, margin: 0 });
      });
      if (i < n - 1) s.addText("▶", { x: x + w, y: y + 0.05, w: gap, h: 0.3, fontSize: 11, color: C.primary, align: "center", valign: "middle", bold: true, margin: 0 });
    });
    return s;
  }

  // 11) 表
  function tableSlide(pres, o) {
    const s = contentSlide(pres, { sectionNo: o.sectionNo, sectionName: o.sectionName, pageNum: o.pageNum });
    const cy = addTitleBlock(s, { title: o.title, takeaway: o.takeaway });
    const h = o.tableH || Math.min(3.2, 0.4 + o.rows.length * 0.55);
    addTable(s, { headers: o.headers, rows: o.rows, x: ML, y: cy + 0.1, w: CW, h, colWidths: o.colWidths });
    return s;
  }

  // 11.5) 図版スライド（drawio 等の外部図を本文領域にアスペクト維持でフィット配置）
  //   image:{path} を leadText/sub の下にセンタリング。任意で最下部に ▶ サマリ帯（meceCards と同形式）。
  function figureSlide(pres, o) {
    const s = contentSlide(pres, { sectionNo: o.sectionNo, sectionName: o.sectionName, pageNum: o.pageNum });
    let cy = addTitleBlock(s, { title: o.title, takeaway: o.takeaway });
    if (o.sub) { s.addText(o.sub, { x: ML, y: cy - 0.05, w: CW, h: 0.35, fontSize: 11, fontFace: F.body, color: C.textGray, margin: 0 }); cy += 0.42; }
    const hasNote = !!o.note;
    const areaY = cy + 0.05;
    const areaBottom = hasNote ? BODY_BOTTOM - 0.6 : BODY_BOTTOM;
    const areaH = areaBottom - areaY, areaW = CW;
    // 画像の実寸からアスペクト比を取り、本文領域に収めてセンタリング（image-size は pptxgenjs の依存）
    let ar = areaW / areaH;
    try { const { imageSize } = require("image-size"); const d = imageSize(o.image.path); ar = d.width / d.height; } catch (e) { console.warn("[raim] image-size 取得失敗、領域いっぱいに配置:", e.message); }
    let w = areaW, h = w / ar;
    if (h > areaH) { h = areaH; w = h * ar; }
    const x = ML + (areaW - w) / 2, y = areaY + (areaH - h) / 2;
    s.addImage({ path: o.image.path, x, y, w, h });
    if (hasNote) {
      const sy = BODY_BOTTOM - 0.5;
      s.addShape("rect", { x: ML, y: sy, w: CW, h: 0.5, fill: { color: C.panelBg }, line: { color: C.primary, width: 1 } });
      // **強調**部分は緑(primaryDark)で持ち帰りポイントを目立たせる
      const runs = parseBold(o.note).map((r) => r.options && r.options.bold ? { text: r.text, options: { bold: true, color: C.primaryDark } } : r);
      s.addText([{ text: "▶  ", options: { bold: true, color: C.primaryDark } }, ...runs], { x: ML + 0.15, y: sy, w: CW - 0.3, h: 0.5, fontSize: 11, fontFace: F.body, color: C.text, valign: "middle", margin: 0 });
    }
    return s;
  }

  // 11.6) 手順（左・縦積み）＋ 縦長スクショ等の画像（右）。手順と“実物の証拠”を1枚で見せる
  function stepsWithImageSlide(pres, o) {
    const s = contentSlide(pres, { sectionNo: o.sectionNo, sectionName: o.sectionName, pageNum: o.pageNum });
    let cy = addTitleBlock(s, { title: o.title });
    if (o.sub) { s.addText(o.sub, { x: ML, y: cy - 0.05, w: CW, h: 0.35, fontSize: 11, fontFace: F.body, color: C.textGray, margin: 0 }); cy += 0.42; }
    const hasNote = !!o.note;
    const areaY = cy + 0.05;
    const areaBottom = hasNote ? BODY_BOTTOM - 0.6 : BODY_BOTTOM;
    const areaH = areaBottom - areaY;
    // 右：画像（1枚 or 複数を右寄せで横並び・高さフィット）
    const imgs = o.images ? o.images : [{ path: o.image.path, caption: o.imageCaption }];
    const capH = imgs.some((im) => im.caption) ? 0.22 : 0;
    const igap = 0.18;
    const aspOf = (p) => { try { const { imageSize } = require("image-size"); const d = imageSize(p); return d.width / d.height; } catch (e) { console.warn("[raim] image-size 取得失敗:", e.message); return 0.75; } };
    const asp = imgs.map((im) => aspOf(im.path));
    let imgH = areaH - capH;
    let block = asp.reduce((sm, a) => sm + imgH * a, 0) + igap * (imgs.length - 1);
    const maxBlock = CW - 3.4 - 0.3; // 左の手順に最低 3.4in 残す
    if (block > maxBlock) { const f = maxBlock / block; imgH *= f; block *= f; }
    let bx = ML + CW - block;
    const blockX0 = bx;
    const imgY = areaY + (areaH - capH - imgH) / 2;
    imgs.forEach((im, k) => {
      const w = imgH * asp[k];
      s.addShape("rect", { x: bx - 0.03, y: imgY - 0.03, w: w + 0.06, h: imgH + 0.06, fill: { color: C.white }, line: { color: C.border, width: 1 } });
      s.addImage({ path: im.path, x: bx, y: imgY, w, h: imgH });
      if (im.caption) s.addText(im.caption, { x: bx - 0.1, y: imgY + imgH + 0.03, w: w + 0.2, h: 0.2, fontSize: 8, fontFace: F.body, color: C.textGray, align: "center", italic: true, margin: 0 });
      bx += w + igap;
    });
    // 左：手順を縦に積む
    const steps = o.steps || [];
    const lw = (blockX0 - 0.35) - ML;
    const n = steps.length, gap = 0.22;
    const sh = (areaH - (n - 1) * gap) / Math.max(n, 1);
    steps.forEach((st, i) => {
      const y = areaY + i * (sh + gap);
      s.addShape("rect", { x: ML, y, w: 0.46, h: 0.46, fill: { color: C.primary } });
      s.addText(st.label || String(i + 1), { x: ML, y, w: 0.46, h: 0.46, fontSize: 15, fontFace: F.header, color: C.white, bold: true, align: "center", valign: "middle", margin: 0 });
      s.addText(st.title, { x: ML + 0.58, y: y - 0.02, w: lw - 0.58, h: 0.32, fontSize: 13, fontFace: F.header, color: C.primaryDark, bold: true, valign: "middle", margin: 0 });
      s.addText(parseBold(st.body), { x: ML + 0.58, y: y + 0.3, w: lw - 0.58, h: sh - 0.3, fontSize: 11, fontFace: F.body, color: C.text, valign: "top", lineSpacingMultiple: 1.02, fit: "shrink", margin: 0 });
    });
    if (hasNote) {
      const sy = BODY_BOTTOM - 0.5;
      s.addShape("rect", { x: ML, y: sy, w: CW, h: 0.5, fill: { color: C.panelBg }, line: { color: C.primary, width: 1 } });
      const runs = parseBold(o.note).map((r) => r.options && r.options.bold ? { text: r.text, options: { bold: true, color: C.primaryDark } } : r);
      s.addText([{ text: "▶  ", options: { bold: true, color: C.primaryDark } }, ...runs], { x: ML + 0.15, y: sy, w: CW - 0.3, h: 0.5, fontSize: 11, fontFace: F.body, color: C.text, valign: "middle", margin: 0 });
    }
    return s;
  }

  // 11.7) KPI（左に縦積みの小カード）＋ 画像（右）。スペックの裏取り実機などを横に添える
  function metricsWithImageSlide(pres, o) {
    const s = contentSlide(pres, { sectionNo: o.sectionNo, sectionName: o.sectionName, pageNum: o.pageNum });
    const cy = addTitleBlock(s, { title: o.title, takeaway: o.takeaway });
    const areaY = cy + 0.1;
    const footH = o.footnote ? 0.26 : 0;
    const areaH = (BODY_BOTTOM - footH) - areaY;
    const leftW = o.leftW || 3.0, gap = 0.3, capH = o.imageCaption ? 0.24 : 0;
    // 右：画像（高さフィット・アスペクト維持・右寄せ）
    let ar = 2;
    try { const { imageSize } = require("image-size"); const d = imageSize(o.image.path); ar = d.width / d.height; } catch (e) { console.warn("[raim] image-size 取得失敗:", e.message); }
    let imgH = areaH - capH, imgW = imgH * ar;
    const maxW = CW - leftW - gap;
    if (imgW > maxW) { imgW = maxW; imgH = imgW / ar; }
    const imgX = ML + CW - imgW, imgY = areaY + (areaH - capH - imgH) / 2;
    s.addShape("rect", { x: imgX - 0.03, y: imgY - 0.03, w: imgW + 0.06, h: imgH + 0.06, fill: { color: C.white }, line: { color: C.border, width: 1 } });
    s.addImage({ path: o.image.path, x: imgX, y: imgY, w: imgW, h: imgH });
    if (o.imageCaption) s.addText(o.imageCaption, { x: imgX - 0.2, y: imgY + imgH + 0.03, w: imgW + 0.4, h: 0.2, fontSize: 8, fontFace: F.body, color: C.textGray, align: "center", italic: true, margin: 0 });
    // 左：メトリクスを縦に積む（小カード）
    const m = o.metrics || [], n = m.length, vgap = 0.2;
    const mh = (areaH - (n - 1) * vgap) / Math.max(n, 1);
    m.forEach((mm, i) => {
      const y = areaY + i * (mh + vgap);
      s.addShape("rect", { x: ML, y, w: leftW, h: mh, fill: { color: C.panelBg }, line: { color: C.border, width: 0.5 } });
      s.addShape("rect", { x: ML, y, w: 0.07, h: mh, fill: { color: C.primary } });
      s.addText([{ text: mm.value, options: { fontSize: 26, bold: true, color: C.primaryDark } }, { text: mm.unit ? (" " + mm.unit) : "", options: { fontSize: 12, bold: true, color: C.primaryDark } }],
        { x: ML + 0.18, y, w: 1.15, h: mh, fontFace: F.header, align: "left", valign: "middle", margin: 0 });
      s.addText(mm.label, { x: ML + 1.4, y: y + 0.1, w: leftW - 1.5, h: 0.3, fontSize: 12, fontFace: F.header, color: C.text, bold: true, valign: "top", margin: 0 });
      if (mm.note) s.addText(mm.note, { x: ML + 1.4, y: y + 0.4, w: leftW - 1.5, h: mh - 0.45, fontSize: 8.5, fontFace: F.body, color: C.textGray, valign: "top", lineSpacingMultiple: 1.0, fit: "shrink", margin: 0 });
    });
    if (o.footnote) s.addText(parseBold(o.footnote), { x: ML, y: BODY_BOTTOM - footH + 0.02, w: CW, h: 0.22, fontSize: 8.5, fontFace: F.body, color: C.textGray, italic: true, valign: "middle", margin: 0 });
    return s;
  }

  // 12) 裏表紙（RAIM_CLOSING マスター：背景・緑帯・白ロゴ・会社情報は固定、メッセージはプレースホルダ）
  function closingSlide(pres, o) {
    o = o || {};
    const s = pres.addSlide({ masterName: "RAIM_CLOSING" });
    s.addText(o.message || "Thank you", { placeholder: "closeMsg" });
    return s;
  }

  // 生成後の後処理: RAIM_BODY レイアウトに「ページ番号フィールド(slidenum)」を通常図形として焼き込む。
  // → レイアウトの非プレースホルダ図形は、そのレイアウトを使う全スライド（既存・PowerPointで追加した新規）に
  //   自動表示され、各スライドの番号を表示する。ヘッダー/フッター設定にも依存しない。
  async function bakeLayoutPageNumber(file) {
    const buf = fs.readFileSync(file);
    const zip = await JSZip.loadAsync(buf);
    const layoutPaths = Object.keys(zip.files).filter((f) => /^ppt\/slideLayouts\/slideLayout\d+\.xml$/.test(f));
    let target = null;
    for (const f of layoutPaths) {
      const x = await zip.file(f).async("string");
      if (x.includes("RAIM_BODY")) { target = f; break; } // レイアウト名 RAIM_BODY で特定（© 表記に依存しない）
    }
    if (!target) { console.warn("[raim] RAIM_BODY レイアウトが見つからず、ページ番号を焼き込めませんでした"); return; }
    let xml = await zip.file(target).async("string");
    if (!xml.includes('name="RaimPageNum"')) {
      const EMU = 914400;
      const x = Math.round((W - MR - 0.4) * EMU), y = Math.round((H - 0.34) * EMU);
      const cx = Math.round(0.4 * EMU), cy = Math.round(0.22 * EMU);
      const sp =
        `<p:sp><p:nvSpPr><p:cNvPr id="991" name="RaimPageNum"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>` +
        `<p:spPr><a:xfrm><a:off x="${x}" y="${y}"/><a:ext cx="${cx}" cy="${cy}"/></a:xfrm>` +
        `<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>` +
        `<p:txBody><a:bodyPr lIns="0" tIns="0" rIns="0" bIns="0" anchor="ctr"/><a:lstStyle/>` +
        `<a:p><a:pPr algn="r"/><a:fld id="{91240B29-F687-4F45-9708-019B960494DF}" type="slidenum">` +
        `<a:rPr lang="ja-JP" sz="900"><a:solidFill><a:srgbClr val="${C.textGray}"/></a:solidFill>` +
        `<a:latin typeface="${T.fonts.tagline}"/></a:rPr><a:t>2</a:t></a:fld></a:p></p:txBody></p:sp>`;
      xml = xml.replace("</p:spTree>", sp + "</p:spTree>");
      zip.file(target, xml);
      const out = await zip.generateAsync({ type: "nodebuffer", compression: "DEFLATE" });
      fs.writeFileSync(file, out);
    }
  }

  // デッキ書き出し（writeFile + ページ番号の焼き込み）。build からは原則これを使う。
  async function writeDeck(pres, fileName) {
    await pres.writeFile({ fileName });
    await bakeLayoutPageNumber(fileName);
    return fileName;
  }

  return {
    pptxgen, T, W, H, ML, MR, CW,
    setDeck, createPresentation, counter, parseBold, writeDeck,
    addLogo, addFooter, contentSlide, addTitleBlock, addExhibit, addCard, addTable,
    coverSlide, agendaSlide, dividerSlide, bulletSlide, execSummarySlide,
    meceCardsSlide, pyramidSlide, numbersSlide, comparisonSlide, timelineSlide, tableSlide, figureSlide, stepsWithImageSlide, metricsWithImageSlide, closingSlide,
  };
};
