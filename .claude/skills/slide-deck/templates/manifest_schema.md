# Manifest Schema — 各レイアウト型のYAML仕様

manifestルート構造:

```yaml
deck:
  title: "..."          # ヘッダーに表示
  client: "..."         # 任意
  project_code: "..."   # 任意
  date: "2026-05-04"
  confidentiality: "Confidential"  # 任意
  accent: "blue"        # "blue" or "gold"
slides:
  - layout: <型名>
    # 型ごとのフィールド
```

`accent` はデッキ全体で1色固定（仕様の制約）。

## 共通フィールド

すべての本文スライドは:
- `section_no`: "01" 等（章番号、自動採番されない場合に指定）
- `section_name`: "Executive Summary" 等
- `notes`: スピーカーノート（任意）

## レイアウト型

### Cover_Consulting

```yaml
- layout: Cover_Consulting
  big_title: "結論を表す一文または提案タイトル"
  tagline: "With Narrative Intelligence"  # 省略可（デフォルト適用）
  subtitle: "Prepared for {クライアント名}"  # 任意
```

### ExecSummary_1pager

```yaml
- layout: ExecSummary_1pager
  section_no: "01"
  section_name: "Executive Summary"
  title: "So Whatの結論一文（数値や比較語を含めるとベター）"
  takeaway: "反転帯1行（最大1行）"
  bullets:
    - "太字始まり：根拠1"
    - "太字始まり：根拠2"
    - "太字始まり：根拠3"        # 最大3
  exhibits:                      # 最大3、左大+右小×2の配置
    - label: "Exhibit 1"
      title: "図が示す事実（短句）"
      source: "出典・期間・単位"   # 必須
      notes: "定義/前提"           # 任意
      # 図はプレースホルダ枠を生成。後でユーザーが画像/グラフを差し込む
    - label: "Exhibit 2"
      title: "..."
      source: "..."
  implications:                  # 最大2
    - "Decide: ..."
    - "Next: ..."
```

### KeyFindings_MECE_3to5

```yaml
- layout: KeyFindings_MECE_3to5
  section_no: "02"
  section_name: "Key Findings"
  title: "MECEで分解した結論一文"
  cards:                          # 3〜5枚（4以上は2x2レイアウト）
    - no: "01"
      heading: "名詞句の見出し"
      body: "短文の説明"
    - no: "02"
      heading: "..."
      body: "..."
  summary_support: "補助1行"       # 任意（summary_zoneに表示）
```

### Pyramid_Principle

```yaml
- layout: Pyramid_Principle
  section_no: "03"
  section_name: "Pyramid"
  title: "..."
  top_conclusion: "結論（panel.dark帯で表示）"
  middle_supports:                # 2〜3
    - "根拠1"
    - "根拠2"
    - "根拠3"
  bottom_facts:                   # Exhibit枠の表/小チャート
    - label: "Exhibit 1"
      title: "..."
      source: "..."
```

### Options_2col_Tradeoff

```yaml
- layout: Options_2col_Tradeoff
  section_no: "04"
  section_name: "Options"
  title: "推奨を断定するタイトル"
  axes:                           # 比較軸 3〜5
    - "コスト"
    - "リードタイム"
    - "リスク"
  option_a:
    name: "Option A"
    cells: ["...", "...", "..."]  # axesと同数
    recommended: false
  option_b:
    name: "Option B"
    cells: ["...", "...", "..."]
    recommended: true              # gold短下線で強調
```

### Rec_Recommendation

```yaml
- layout: Rec_Recommendation
  section_no: "05"
  section_name: "Recommendation"
  title: "推奨を一文で断定"
  takeaway: "1行サマリー"          # 任意
  supports:                       # 根拠3点（左レール強調）
    - "根拠1"
    - "根拠2"
    - "根拠3"
  evidence_refs:                  # Exhibit参照（必須）
    - "Exhibit 1"
    - "Exhibit 2"
```

### Roadmap_Gantt_Light

```yaml
- layout: Roadmap_Gantt_Light
  section_no: "06"
  section_name: "Plan"
  title: "..."
  phases:                         # 3〜5
    - { name: "Phase 1", start: "2026-Q2", end: "2026-Q3", critical: true }
    - { name: "Phase 2", start: "2026-Q3", end: "2026-Q4", critical: false }
    - { name: "Phase 3", start: "2026-Q4", end: "2027-Q1", critical: false }
  milestones:                     # 任意
    - { date: "2026-09-30", label: "MVP" }
  notes_footer: "期間/前提の注記"
```

### Risks_Mitigations_Table

```yaml
- layout: Risks_Mitigations_Table
  section_no: "07"
  section_name: "Risks"
  title: "..."
  rows:
    - risk: "..."
      impact: "High"        # High/Med/Low
      likelihood: "Med"
      mitigation: "..."
      owner: "..."
      severe: true          # trueの場合 status.bad で強調（小面積）
```

### Appendix_Exhibits

```yaml
- layout: Appendix_Exhibits
  section_no: "A1"
  section_name: "Appendix"
  exhibit:
    label: "Exhibit A1"
    title: "..."
    source: "..."
    notes: "..."
```

1スライド1Exhibit。複数あれば複数slideに分ける。

## バリデーション規則（builder側でチェック）

- title が「〜について」「〜の概要」を含む場合、警告を出す
- Exhibit数 > 3 の場合エラー
- ExecSummaryのbullets > 3 の場合エラー
- Exhibitに source が無い場合エラー
- accent が blue/gold 以外の場合エラー
