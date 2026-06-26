// theme.js — Raim Technologies コーポレート・テーマトークン
// 配色は「上品ミックス」: 白基調・本文チャコール、アクセントにブランド緑、帯/章扉に濃緑。
// raim_helpers.js のヘルパーはすべてこの theme から色・フォントを引く（色コードの直書き禁止）。
// 後で jings-slides 形式のスキルへ移植する際は、この 1 ファイルを差し替えるだけで配色を変えられる。

const path = require("path");

const theme = {
  colors: {
    // ── ブランド3色（ロゴ由来） ──
    primary:     "1DBD4D", // ブランド緑：アクセント下線・章番号タグ・見出しバー・▶マーカー
    primaryLight:"7FE3A1", // 明るい緑：濃緑背景上のラベル・章扉の番号（コントラスト確保用）
    primaryDark: "13A13E", // 濃緑：takeaway 帯・テーブルヘッダ・章扉背景
    navy:        "0B6E2B", // 最濃緑：強調ノード・ロードマップ後期（締め色）。※名称は slidecraft 互換のため "navy" だが実体は緑。別ブランド移植時は色を入れ替えること
    text:        "2E2E2E", // チャコール：タイトル・本文（ロゴの文字色と一致）

    // ── 補助色 ──
    textGray:    "707070",
    accent:      "E03535", // 注意・機密枠（赤）
    amber:       "C8881A", // 注記ボックスの枠
    amberBg:     "FFF6E0", // 注記ボックス背景
    panelBg:     "EAF7EE", // 淡い緑パネル（結論ボックス・カード背景）
    lightGray:   "F4F7F5", // テーブル偶奇縞・プレースホルダ背景
    border:      "DDDDDD",
    gray:        "C8C8C8",
    copyright:   "9A9A9A", // 白地フッターのコピーライト
    footerOnDark:"DCEFE2", // 濃緑地フッターのコピーライト（淡い緑がかった白）
    white:       "FFFFFF",
  },

  fonts: {
    // Yu Gothic UI が無い環境では raim_helpers 側で Meiryo UI → Noto Sans CJK JP に自動フォールバック
    header:  "Yu Gothic UI",
    body:    "Yu Gothic UI",
    tagline: "Calibri", // 英字キャプション・ページ番号・コピーライト
  },

  // ロゴ（assets/）。dark=白〜淡色背景用（緑＋チャコール）／ light=濃緑背景用（白抜き）
  logo: {
    dark:        path.join(__dirname, "assets", "raim-logo.png"),
    light:       path.join(__dirname, "assets", "raim-logo-white.png"),
    symbol:       path.join(__dirname, "assets", "raim-symbol.png"),
    symbolLight:  path.join(__dirname, "assets", "raim-symbol-white.png"),
    aspect:       2.9,   // 横ロゴ（symbol+type）の w/h 比
    symbolAspect: 0.835, // シンボル単体の w/h 比
    tagline:      null,  // 確定タグラインが無いため未設定（決まれば文字列を入れる）
  },

  // フッター機密ラベル（TLP v2 運用に準拠。テンプレ既定は AMBER。公開資料は build 側で "TLP:CLEAR" に差し替え）
  confidentialLabel: "TLP:AMBER",

  // 章扉の背景画像（任意）。null なら primaryDark の単色
  dividerBg: null,

  year: "2026",

  // 会社情報（裏表紙・会社概要レイアウトで使用。※印は要確認のプレースホルダ）
  company: {
    nameJa:    "株式会社Ｒａｉｍテクノロジーズ",
    nameEn:    "Raim Technologies, Inc.",
    copyright: "© 株式会社Raimテクノロジーズ", // フッター著作権表記（年なし・Raim は半角）
    founded: "2025年12月5日",
    ceo:     "高島 湊斗",
    capital: "10万円",
    hq:      "〒450-0002 愛知県名古屋市中村区名駅3-4-10 アルティメイト名駅1st 2階",
    office:  "静岡県浜松市",
    email:   "info@raim-tech.com",      // ※要確認
    url:     "https://raim-tech.com",   // ※要確認
  },
};

module.exports = theme;
