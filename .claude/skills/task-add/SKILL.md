---
name: task-add
description: Raim-technologies/task-takashima リポジトリの Issue を操作する。新規 Issue 作成と、既存 Issue への進捗コメント投稿の 2 モード。「タスク追加して」「PM タスク化」「task-takashima に登録」「後でやる用にタスクに入れて」「TODO に積んで」「Issue 立てて」(新規モード) / 「Issue #N に進捗書いて」「task-takashima の N にコメント」「進捗を Issue に追記」「○○が完了した、Issue にメモして」(コメントモード) などで起動。各プロジェクトのワーキングディレクトリから呼んでも常に task-takashima repo に向けて発行する。
argument-hint: "<タイトル or '#N コメント本文'> [--priority P0|P1|P2|P3] [--stream <stream>] [--due YYYY-MM-DD] [--estimate <hours>] [--type Task|Bug|Feature|Idea|Decision] [--iteration current]"
disable-model-invocation: false
allowed-tools: Bash
context: fork
agent: general-purpose
---

# task-add スキル

`Raim-technologies/task-takashima` リポジトリの Issue を操作する。次の 2 モード:

- **モード A: 新規 Issue 作成** — Issue を立てて org Project #9 "task-takashima" に登録
- **モード B: 既存 Issue にコメント投稿** — 進捗 / メモ / 完了報告などを Issue コメントとして残す

各プロジェクトのワーキングディレクトリから呼んでも、対象は常に `task-takashima` repo。`gh ... --repo Raim-technologies/task-takashima` のように **常に明示的に repo 指定**する。

## モード判定 (最初に必ず実行)

ユーザーの発話 / 引数から下記いずれかに分類:

| シグナル                                          | モード     |
|--------------------------------------------------|-----------|
| Issue 番号 (`#N` / `Issue 12` 等) を伴う発話     | **B (コメント)** |
| 「コメント」「追記」「進捗」「メモして」等の語   | **B (コメント)** |
| 「タスク追加」「立てて」「登録」「TODO に積む」等  | **A (新規作成)** |
| 何も特定できない                                  | ユーザーに 1 度確認 |

両方の条件が同時に成立しうる場合 (例: 「Issue #5 を起点に新規タスク」) はモード A + 本文に親 Issue リンクを記載するのが自然。判断に迷ったらユーザーに確認すること。

## 動作原則 (共通)

1. **書き込み専用**: このスキルは Issue 作成 / コメント投稿のみ行う。削除・field の大幅編集は別経路で
2. **必ず最後に URL を返す**: モード A は Issue URL、モード B はコメント URL (`gh issue comment --json` の結果 or Issue URL + #issuecomment-N)
3. **個人情報・機密の取扱注意**: private repo だが、給与/顧客クレーム等の生々しい情報は本文に書きすぎない

## 固定リソース

```
REPO        = Raim-technologies/task-takashima
PROJECT_ID  = PVT_kwDODq8Af84BYVjW
PROJECT_NUM = 9
OWNER       = Raim-technologies
```

### Custom Field IDs

| Field    | DataType      | Field ID                              |
|----------|---------------|---------------------------------------|
| Status   | SINGLE_SELECT | PVTSSF_lADODq8Af84BYVjWzhTcH1w        |
| Priority | SINGLE_SELECT | PVTSSF_lADODq8Af84BYVjWzhTcIO8        |
| Due      | DATE          | PVTF_lADODq8Af84BYVjWzhTcIPA          |
| Estimate | NUMBER        | PVTF_lADODq8Af84BYVjWzhTcIPE          |
| Stream   | SINGLE_SELECT | PVTSSF_lADODq8Af84BYVjWzhTcIPI        |
| Iteration| ITERATION     | PVTIF_lADODq8Af84BYVjWzhTcIRM         |

### Status options

| Name        | Option ID  |
|-------------|------------|
| Todo        | ccc31e63   |
| In Progress | ddfd304c   |
| Blocked     | efcb3cdc   |
| Done        | d9b51ea9   |

### Priority options

| Name | Option ID  | 意味 (時間軸固定) |
|------|------------|------------------|
| P0   | 7642282d   | 今日中            |
| P1   | 52665cee   | 今週内            |
| P2   | db1e06d6   | 今月内            |
| P3   | 4a375bab   | いつか            |

### Stream options

| Name                  | Option ID  |
|----------------------|------------|
| MeTalk               | ab561dd5   |
| holoplax             | 3f901e2e   |
| jings                | f10557f8   |
| oasis                | 3a00080a   |
| senren               | 4c720be0   |
| wheretruck           | 9cb3a0cb   |
| アウターク            | cd772e0e   |
| コルモアナ            | a89e8388   |
| デジタルレシピ        | 612ac37d   |
| 中日ステンドアート    | 0bdd5a24   |
| 信陽エンジニアリング  | 3121c806   |
| 岡山県                | 4da2acc7   |
| 竹内先生              | 63fc8053   |
| 社内                  | 0ca918f0   |
| 個人                  | 0bc670a4   |
| 営業                  | d2f0f83f   |
| 研究                  | 1a4427d3   |
| kuuron                | 1297c049   |
| その他                | 6f94481b   |

## モード A: 新規 Issue 作成

### Step A-1: 入力の正規化

- タイトル: 引数または文脈から決定
- 本文 (`BODY`): 以下のスケルトンに沿って生成

```markdown
## 目的 / Why

<会話文脈から書ける場合のみ記入。書けない場合は空のまま>

## 完了条件 / DoD
- [ ] <可能なら 1〜3 個の checklist 項目を提示。なければ空のチェック 1 個のまま>

## 背景・参考リンク

<関連 URL、Issue 番号、ファイル参照などがあれば貼る。なければ空>

## メモ

<その他、AI が把握している補足。なければ空>
```

- フラグの値検証:
  - `--priority`: `P0|P1|P2|P3` 以外は弾く
  - `--stream`: 上記 Stream options のいずれかに一致しない場合は弾く
  - `--type`: `Task|Bug|Feature|Idea|Decision` 以外は弾く
  - `--due`: `YYYY-MM-DD` 形式
  - `--estimate`: 数値 (時間)
  - `--iteration current`: 現在の Iteration を意味 (`gh api graphql` で取得)

### Step A-2: Issue を作成

```bash
gh issue create \
  --repo Raim-technologies/task-takashima \
  --title "<TITLE>" \
  --body "<BODY>"
```

返ってきた Issue URL を変数 `ISSUE_URL` に格納。Issue 番号は URL の末尾。

`--type` 指定がある場合は、Issue 作成後に Issue Type を設定:

```bash
gh issue edit <N> --repo Raim-technologies/task-takashima --add-label-or-issue-type ...
```

注: 2026 年時点で `gh issue create --type` フラグが利用可能なら直接指定。利用不可なら GraphQL `updateIssueIssueType` mutation を使う。具体的には:

```bash
gh api graphql -f query='
mutation($issueId: ID!, $typeId: ID!) {
  updateIssueIssueType(input: {issueId: $issueId, issueTypeId: $typeId}) {
    issue { id }
  }
}' -F issueId=<ISSUE_NODE_ID> -F typeId=<TYPE_NODE_ID>
```

Issue Type の node ID は `gh api /orgs/Raim-technologies/issue-types --jq '.[] | select(.name=="<TypeName>") | .node_id'` で取得。

### Step A-3: Project に追加

Auto-add workflow が走るが、即時実行されないこともあるので明示的に追加 (idempotent):

```bash
ITEM_ID=$(gh project item-add 9 --owner Raim-technologies --url "$ISSUE_URL" --format json --jq '.id')
```

### Step A-4: Custom Field を設定 (フラグ指定がある場合のみ)

```bash
# 例: Priority = P1
gh project item-edit \
  --id "$ITEM_ID" \
  --project-id PVT_kwDODq8Af84BYVjW \
  --field-id PVTSSF_lADODq8Af84BYVjWzhTcIO8 \
  --single-select-option-id 52665cee

# 例: Stream = holoplax
gh project item-edit \
  --id "$ITEM_ID" \
  --project-id PVT_kwDODq8Af84BYVjW \
  --field-id PVTSSF_lADODq8Af84BYVjWzhTcIPI \
  --single-select-option-id 3f901e2e

# 例: Due = 2026-06-01
gh project item-edit \
  --id "$ITEM_ID" \
  --project-id PVT_kwDODq8Af84BYVjW \
  --field-id PVTF_lADODq8Af84BYVjWzhTcIPA \
  --date 2026-06-01

# 例: Estimate = 2 (時間)
gh project item-edit \
  --id "$ITEM_ID" \
  --project-id PVT_kwDODq8Af84BYVjW \
  --field-id PVTF_lADODq8Af84BYVjWzhTcIPE \
  --number 2
```

#### Iteration を current にする場合

現在の Iteration ID を取得して指定:

```bash
ITER_ID=$(gh api graphql -f query='
query {
  node(id: "PVTIF_lADODq8Af84BYVjWzhTcIRM") {
    ... on ProjectV2IterationField {
      configuration { iterations { id startDate duration } }
    }
  }
}' --jq '.data.node.configuration.iterations[0].id')

gh project item-edit \
  --id "$ITEM_ID" \
  --project-id PVT_kwDODq8Af84BYVjW \
  --field-id PVTIF_lADODq8Af84BYVjWzhTcIRM \
  --iteration-id "$ITER_ID"
```

注: `configuration.iterations` は今後の Iteration リストを返す。今日が含まれる Iteration を判定したい場合は `startDate` と `duration` から計算する。

### Step A-5: ユーザーに結果を返す

```
✅ Issue #<N> を作成しました
URL: <ISSUE_URL>
タイトル: <TITLE>
[設定したフィールド一覧 (あれば)]
```

## モード B: 既存 Issue にコメント投稿

進捗報告・メモ・完了報告・気付きなどを Issue コメントとして残す。

### Step B-1: 対象 Issue 番号を確定

- 引数 / 発話から `#N` を抽出。Issue 番号が無ければユーザーに確認 (推測しない)
- 必要なら `gh issue view <N> --repo Raim-technologies/task-takashima --json title,state,number,body` で対象 Issue の存在 / 概要を確認
- close 済みの Issue にコメントしてもよいが、Done 済みであることをユーザーに念のため告げる

### Step B-2: コメント本文を生成

優先順位:
1. ユーザーが具体的なコメント本文を渡している → そのまま使う
2. 渡されていない / 抽象的 (「進捗書いて」だけ等) → 会話文脈から AI が要約してドラフト。送信前に内容をユーザーに見せて承認を取る
3. 進捗 / メモを構造化したい場合は、以下のテンプレを参考に整形 (型を強制はしない):

```markdown
### 進捗 (YYYY-MM-DD)

- やったこと:
  - ...
- 次にやること / ブロッカー:
  - ...
- 補足:
  - ...
```

日付は今日の日付。短文コメント (1〜3 行) で十分なケースが多いので、構造化は無理に押し付けない。

### Step B-3: コメントを投稿

```bash
gh issue comment <N> --repo Raim-technologies/task-takashima --body "<BODY>"
```

出力に Comment URL (例: `https://github.com/Raim-technologies/task-takashima/issues/<N>#issuecomment-<C>`) が含まれるので保持。

### Step B-4 (オプション): 進捗に応じて Status / Iteration を更新

ユーザーが明示した場合のみ。例:
- 「これで完了」「Done にして」→ Status を `Done` (option ID: `d9b51ea9`) に変更し、Issue を close
- 「ブロッカーが発生」→ Status を `Blocked` (option ID: `efcb3cdc`) に変更し、必要に応じて `waiting:*` ラベルを付与
- 「着手した」→ Status を `In Progress` (option ID: `ddfd304c`) に変更

手順 (Status を Done に変える例):

```bash
# 1. Project item の ID を取得 (Issue 番号で検索)
ITEM_ID=$(gh project item-list 9 --owner Raim-technologies --format json --limit 200 \
  | jq -r --arg n "<N>" '.items[] | select(.content.number == ($n | tonumber)) | .id')

# 2. Status を Done に更新
gh project item-edit \
  --id "$ITEM_ID" \
  --project-id PVT_kwDODq8Af84BYVjW \
  --field-id PVTSSF_lADODq8Af84BYVjWzhTcH1w \
  --single-select-option-id d9b51ea9

# 3. Issue を close (Done を表現するため)
gh issue close <N> --repo Raim-technologies/task-takashima --reason completed
```

ラベル追加例:

```bash
gh issue edit <N> --repo Raim-technologies/task-takashima --add-label "waiting:client-reply"
```

ラベル削除例:

```bash
gh issue edit <N> --repo Raim-technologies/task-takashima --remove-label "waiting:client-reply"
```

### Step B-5: ユーザーに結果を返す

```
✅ Issue #<N> にコメントを追加しました
コメント URL: <COMMENT_URL>
[Status 変更や close を行った場合はその旨も]
```

## エラーハンドリング

- `gh` が未認証: `gh auth login` を促す
- `gh issue create` / `gh issue comment` が失敗 (権限不足など): エラー本文をそのまま見せる
- 対象 Issue が存在しない (モード B): Issue 番号の取り違いを疑い、`gh issue list --repo Raim-technologies/task-takashima` 等で確認するようユーザーに促す
- Custom Field 設定が失敗: Issue / コメント自体は成功しているので、その旨を伝えて URL を返す (ロールバックしない)

## 使用例

### 例 1: シンプルな新規タスク
> ユーザー: "経費精算をタスクに追加して"

→ モード A、タイトル「経費精算」、本文はスケルトンのみ、Stream は文脈から「個人」or「社内」を提案 (確信があれば設定、なければ未設定)

### 例 2: 詳細指定での新規タスク
> ユーザー: "holoplax の請求書発行を P1 で立てて、明日まで"

→ モード A、タイトル「holoplax 請求書発行」、`--priority P1 --stream holoplax --due <明日の日付>`

### 例 3: 既存 Issue への進捗コメント
> ユーザー: "Issue #12 に進捗書いて: 田中さんに連絡済み、来週返答待ち"

→ モード B、対象 #12、本文 "田中さんに連絡済み、来週返答待ち"。Status を Blocked に変えるかは聞かない (明示されていないため)

### 例 4: 完了報告 + Done に
> ユーザー: "Issue #5 終わった、Done にして"

→ モード B、対象 #5、コメント本文 (要約 or 「完了しました」)、Status を Done に変更、Issue を close

### 例 5: ブロッカー報告
> ユーザー: "Issue #8、クライアントの返信待ちで進められない"

→ モード B、対象 #8、コメント本文、Status を Blocked に変更、`waiting:client-reply` ラベルを付与 (要確認)

## 注意

- **このスキルは task-takashima への書き込み専用**。他の repo に Issue を立てたい場合は別の手段を使うこと
- 機密性の高い内容は Issue 本文 / コメントに書かない (private repo だが、念のため給与/顧客クレーム等は Issue タイトルだけにし詳細はローカルに残す等の判断を)
- Stream リストは将来見直し予定 (`~/workspace/pm/decisions/custom-fields.md` を参照)
- モード B でコメント本文を AI が起こした場合は、**送信前に必ずユーザーに見せて承認を取る** (ユーザーが具体的な本文を渡している場合は確認不要)
