// build_example.js — Raim コーポレート・テンプレートの「見本デッキ」を生成
// 各レイアウト関数を 1 枚ずつ並べ、配色・タイポ・余白を一望できるサンプルにする。
// 文言は実データ寄りのダミー（テンプレ利用時に差し替える前提）。これをコピーして自分のデッキを作る。
//   node build_example.js  →  Raim_Template_2026.pptx

const path = require("path");
const D = require("./raim_helpers")(require("./theme"));

D.setDeck({ title: "コーポレート・テンプレート 見本" });

(async () => {
  const pres = D.createPresentation("Raim Technologies コーポレートテンプレート 2026");
  // ページ番号は RAIM_BODY マスターのネイティブ番号フィールドで自動採番（手動カウンタ不要）

  // 1) 表紙
  D.coverSlide(pres, {
    bigTitle: "会社・サービスを伝えるための\nコーポレート・スライド・テンプレート",
    subtitle: "Raim Technologies 標準フォーマット",
    audience: "提案・会社案内・採用 共通",
    date: "2026",
    confidentiality: "TLP:AMBER",
  });

  // 2) 目次（このデッキが含むレイアウト一覧を兼ねる）
  D.agendaSlide(pres, {
    title: "このテンプレートに含まれるレイアウト",
    items: [
      { no: "01", name: "エグゼクティブサマリ（1pager）" },
      { no: "02", name: "MECE カード（3〜5枚）" },
      { no: "03", name: "ピラミッド（結論→根拠→事実）" },
      { no: "04", name: "数値ハイライト（KPI）" },
      { no: "05", name: "比較（2カラム） / タイムライン / 表 / 箇条書き" },
    ],
  });

  // 章扉
  D.dividerSlide(pres, { sectionNo: "01", title: "エグゼクティブサマリ" });

  // 3) エグゼクティブサマリ
  D.execSummarySlide(pres, {
    sectionNo: "01", sectionName: "Executive Summary",
    title: "Raim は名古屋・浜松を拠点に、Web/モバイル/AI まで内製する技術組織",
    takeaway: "創業5ヶ月、第1期は12社超のクライアントと並走中",
    bullets: [
      "**会社**：株式会社Ｒａｉｍテクノロジーズ／2025年12月5日設立／資本金10万円",
      "**拠点**：本店 愛知県名古屋市中村区名駅、事業所 静岡県浜松市",
      "**事業**：受託開発を主軸に、情報処理コンサル・プログラミングスクールも展開",
    ],
    exhibits: [
      { label: "EXHIBIT 1", title: "事業領域：Web・モバイル・AI・データを横断", source: "案件管理データ 2026-04" },
      { label: "EXHIBIT 2", title: "クライアント数：12社超", source: "案件管理データ 2026-04" },
      { label: "EXHIBIT 3", title: "代表者：高島湊斗（2006年生）", source: "登記情報 2026-04" },
    ],
    decide: "まずは『どんな会社か』をフラットに知ってもらう",
    next: "以降で事業・実績・数字・チームを順に開示",
  });

  // 4) MECE カード
  D.meceCardsSlide(pres, {
    sectionNo: "02", sectionName: "Business",
    title: "事業は『開発・コンサル・教育』の3軸で、顧客のフェーズに応じて使い分ける",
    sub: "顧客の課題フェーズが変わっても、3事業を行き来して継続的に支援できる",
    cards: [
      { no: "01", heading: "受託開発（主軸）", body: "Web・モバイル・AI を企画から運用まで内製。**下請け連鎖はつくらない**。売上の大半を占める。" },
      { no: "02", heading: "情報処理コンサル", body: "技術選定・アーキテクチャ設計・DX 推進をハンズオンで支援。PoC から本番運用まで伴走。" },
      { no: "03", heading: "プログラミングスクール", body: "次世代エンジニア育成と顧客企業のリスキリング。現場知見をカリキュラムに反映。" },
      { no: "04", heading: "横断する共通点", body: "3事業に通底するのは『**少人数で高密度に動く**』こと。意思決定は即日、技術判断はエンジニア起点。" },
    ],
    summary: "領域・規模を問わず受け、長期で組める顧客を見極めて密度を上げる方針",
  });

  // 5) ピラミッド
  D.pyramidSlide(pres, {
    sectionNo: "02", sectionName: "Why & Now",
    title: "『技術を軸に少人数で高密度に動く組織』を作りたくて、2025年末に立ち上げた",
    conclusion: "創業から5ヶ月、当初仮説どおり少人数・高密度のオペレーションが回り始めている",
    supports: [
      "**Why**：下請け連鎖や中間マージンを排し、技術者が直接顧客と対話できる組織が必要だった",
      "**What**：Web/モバイル/AI をフルスタックで内製、PoC から運用まで同じチームで伴走",
      "**Now**：第1期5ヶ月で売上814万円・営業利益率73.5%、12社超と取引中",
    ],
    facts: [
      { label: "EXHIBIT 1", title: "第1期実績サマリ（2025-12〜2026-04）", source: "社内決算 2026-04" },
      { label: "EXHIBIT 2", title: "事業の3軸（開発・コンサル・教育）", source: "事業計画 2026-04" },
    ],
  });

  // 6) 数値ハイライト
  D.numbersSlide(pres, {
    sectionNo: "03", sectionName: "Numbers",
    title: "第1期5ヶ月で売上814万円、営業利益率73.5%。労働集約型ながら高収益で着地中",
    takeaway: "数字も含めフラットに開示（計上遅延などの実情も含めて）",
    metrics: [
      { value: "814", unit: "万円", label: "第1期 売上", note: "2025-12〜2026-03 実績（4月は計上遅延）" },
      { value: "73.5", unit: "%", label: "営業利益率", note: "業界平均10%前後を大きく上回る" },
      { value: "12", unit: "社+", label: "取引クライアント", note: "第1期 累計・多様な業種" },
    ],
  });

  // 7) 比較（2カラム）
  D.comparisonSlide(pres, {
    sectionNo: "04", sectionName: "Positioning",
    title: "多重下請け構造ではなく、顧客と直接つながる内製チームであること",
    sub: "中間マージンと伝言ゲームを排し、意思決定と技術判断のスピードを最大化",
    left: {
      label: "一般的な多重下請け",
      points: ["顧客の要望が**伝言ゲーム**で劣化", "中間マージンでコスト増", "責任の所在が曖昧", "技術者が顧客と話せない"],
    },
    right: {
      label: "Raim の直接内製",
      points: ["顧客と**エンジニアが直接対話**", "中間マージンなし", "企画〜運用まで一気通貫で責任", "意思決定は即日"],
    },
  });

  // 8) タイムライン
  D.timelineSlide(pres, {
    sectionNo: "04", sectionName: "Roadmap",
    title: "受託で収益基盤を固めつつ、第2期は拡大とプロダクト投資を両輪で進める",
    sub: "短期＝収益安定、中期＝体制と仕組み、長期＝事業循環の確立",
    phases: [
      { label: "第1期 〜2026/11", title: "立ち上げ", items: ["受託で収益基盤", "12社と取引", "高利益率で着地"] },
      { label: "第2期", title: "拡大", items: ["売上拡大とキャッシュ改善", "採用・体制強化", "プロダクト投資検討"] },
      { label: "中期", title: "確立", items: ["3事業の循環", "ブランド確立", "教育→採用の好循環"] },
    ],
  });

  // 9) 箇条書き本文
  D.bulletSlide(pres, {
    sectionNo: "04", sectionName: "Bullet Sample",
    title: "箇条書きレイアウト（タイトル2層＋ em-dash 箇条書き）の見本",
    takeaway: "1スライド1メッセージ。事実には ▶ で So-What を添える",
    bullets: [
      "**見出し語を太字**にすると、項目の主語が一目で分かる",
      "1行は簡潔に。詳細は Appendix へ逃がし、本編の密度を保つ",
      "数字は可能なら定量で示し、仮値には（仮）を付す",
      "▶ 結論・打ち手は箇条書きの最後に置くと流れが通る",
    ],
  });

  // 10) 表
  D.tableSlide(pres, {
    sectionNo: "04", sectionName: "Table Sample",
    title: "表レイアウト（ヘッダ濃緑・偶奇縞）の見本",
    takeaway: "1枚あたり5行程度までに抑え、溢れたら分割する",
    headers: ["事業", "内容", "位置づけ"],
    rows: [
      ["受託開発", "Web・モバイル・AI を企画から運用まで内製", "主軸（売上の大半）"],
      ["情報処理コンサル", "技術選定・設計・DX 推進をハンズオン支援", "上流からの関与"],
      ["プログラミングスクール", "次世代エンジニア育成・リスキリング", "教育→採用の循環"],
    ],
    colWidths: [2, 4.5, 2.5],
  });

  // 11) 裏表紙
  D.closingSlide(pres, { message: "Thank you" });

  const out = path.join(__dirname, "Raim_Template_2026.pptx");
  await D.writeDeck(pres, out); // writeFile + ページ番号をレイアウトへ焼き込み
  console.log("written:", out);
})().catch((e) => { console.error(e); process.exit(1); });
