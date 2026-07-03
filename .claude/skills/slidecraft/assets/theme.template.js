// theme.template.js — 案件ごとにコピーして theme.js を作る。
// 「色はブランドに合わせる」のが原則。指定が無ければこの中立デフォルトで進め、後で差し替える。
// layout-patterns.md のヘルパーはすべてこの theme オブジェクトから色・フォントを引く（色の直書き禁止）。

const path = require("path");

// ── 中立デフォルトテーマ（ブランド指定が無いとき） ──
const theme = {
  colors: {
    primary:    "2563EB", // メインカラー（ブランド色に差し替える）
    primaryDark:"1D4ED8", // 濃いめ（ヘッダー帯・ロードマップ中期など）
    navy:       "172554", // 最濃（強調ノード・見出し背景）
    accent:     "E11D48", // 強調・注意（★ 印, 危険）
    amber:      "F59E0B", // 注記ボックスの枠
    amberBg:    "FFF6E0", // 注記ボックス背景
    text:       "333333",
    textGray:   "666666",
    white:      "FFFFFF",
    panelBg:    "EEF4FF", // 淡い背景パネル / 結論ボックス背景
    lightGray:  "F5F5F5", // テーブル偶奇縞
    border:     "DDDDDD",
    gray:       "CCCCCC",
    copyright:  "999999",
  },
  fonts: {
    header:  "Yu Gothic UI", // 環境に無ければ生成スクリプト側で Meiryo UI / Noto Sans CJK JP にフォールバック
    body:    "Yu Gothic UI",
    tagline: "Calibri",
  },
  // ロゴ（任意）。null ならロゴ無しで生成
  logo: null,
  // logo: { dark: path.join(__dirname, "assets/logo.png"), light: path.join(__dirname, "assets/logo-white.png"), tagline: "Tagline here" },

  // 機密ラベル（任意）。null ならフッターに出さない
  confidentialLabel: null, // 例: "貴社限り"

  // 区切りスライド背景（任意）。グラデーション画像パス or null（null は primary 単色）
  dividerBg: null,

  year: String(new Date().getFullYear()),
};

module.exports = theme;

/*
── プリセット例: JINGS ブランド ──
colors.primary    = "4472C4"
colors.primaryDark= "2F5597"
colors.navy       = "1F3864"
colors.accent     = "E03535"
colors.panelBg    = "EEF4FF"
fonts.header/body = "Yu Gothic UI"
logo              = { dark: ".../jings-logo-text.png", light: ".../jings-logo-text-white.png", tagline: "AI for the Bold and Ambitious" }
confidentialLabel = "貴社限り"
dividerBg         = ".../gradient_bg.png"

→ つまり jings はこのテーマの 1 プリセット。他ブランドは colors と logo を差し替えるだけ。
*/
