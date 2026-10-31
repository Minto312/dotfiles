---
name: discord-notify
description: Discord (#claude) へ通知メッセージを送信する。時間のかかる作業の完了時や区切りでユーザーに気付かせたいときに使う。「Discord に通知」「完了したら知らせて」「終わったら通知して」などで起動。
argument-hint: "<メッセージ本文> [--title タイトル]"
disable-model-invocation: false
allowed-tools: Bash
---

# Discord 通知スキル

Discord の `#claude` チャンネルへメッセージを送って、作業完了や区切りを知らせる。

送り口は `~/.local/bin/discord-post` (discord-ack)。bot で送り、bot が使えなければ従来の webhook に落とす。
**このセッションの ID が通知に紐付く**ので、ユーザーが Discord でその通知にリプライすると、
discord-ack がこのセッションを分岐 (`--resume --fork-session`) して続きの作業をヘッドレスで行う。

## 資格情報

bot のトークンは `~/.config/discord-ack/env`、予備の webhook は `~/.config/discord-notify/env` にあり、
discord-post が自分で読む。どちらも資格情報なので、会話やログに値を出さない。
他の宛先が欲しい場合はユーザーに明示確認すること。

## 使い方

### 基本の送信手順

1. 送るメッセージ本文を決める。デフォルトで以下を含めると親切:
   - 何の作業が完了/進捗したか (1〜2 行)
   - ホスト名 (このスキルは `develop` で動く想定)
   - 結果ステータス (成功/失敗/要確認)
2. `discord-post` に標準入力で渡す。成功すると投稿したメッセージ ID が出て終了コード 0。
3. 失敗したらエラー出力をユーザーに共有し、原因を調査する。

### 推奨コマンド

```bash
MESSAGE=$(cat <<'EOF'
✅ ビルド完了: my-project
host: develop
所要時間: 14m22s
EOF
)

~/.local/bin/discord-post -c claude <<< "$MESSAGE"
```

- 2000 字を超える本文は行単位で分けて投稿される。レート制限 (429) も discord-post が 1 回だけ待って再送する
- 長い成果物は `--file <パス>` で添付できる (bot で送れたときのみ)
- `discord-post` が無い環境 (develop 以外) では、`~/.config/discord-notify/env` の `DISCORD_WEBHOOK_URL` へ
  `jq -nc --arg content "$MESSAGE" '{content: $content}' | curl -sS -H 'Content-Type: application/json' -X POST -d @- "$DISCORD_WEBHOOK_URL"` で送る

### 引数の解釈

- 位置引数のすべてをスペース連結したものを本文として扱う。
- `--title <文字列>` が与えられた場合は、本文先頭に `**<タイトル>**` を付け、改行で本文を続ける。
- メッセージ本文が空のときは送らず、ユーザーに内容を確認する。

## 典型的な使いどころ

- 長いビルド、テスト、デプロイ、ダウンロード、バックアップなどの完了通知
- 複数タスクを並走させているときの、各タスクの完了タイミング通知
- エラー終了時の即時通知 (成功時は省略、など運用で調整)

## やってはいけないこと

- bot のトークンや webhook の URL をチャットやログに平文で出力する (知っている人は誰でも投稿できる)
- ユーザーから明示の依頼がないのに通知を送る (このスキルはユーザーの明示指示でのみ起動する)
- 機密情報 (鍵、トークン、個人情報、顧客データ) を本文に含める
