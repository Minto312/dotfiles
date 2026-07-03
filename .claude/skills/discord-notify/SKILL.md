---
name: discord-notify
description: Discord webhook へ通知メッセージを送信する。時間のかかる作業の完了時や区切りでユーザーに気付かせたいときに使う。「Discord に通知」「完了したら知らせて」「終わったら通知して」などで起動。
argument-hint: "<メッセージ本文> [--title タイトル]"
disable-model-invocation: false
allowed-tools: Bash
---

# Discord 通知スキル

Discord の Incoming Webhook へメッセージを POST して、作業完了や区切りを知らせる。

## Webhook URL

Webhook URL は資格情報のため **リポジトリには含めず**、gitignore 済みの `~/.config/discord-notify/env` から読み込む。このファイルには次の 1 行を置く:

```
DISCORD_WEBHOOK_URL='https://discord.com/api/webhooks/xxxxxxxxxxxxxxxxxxx/xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
```

他の宛先が欲しい場合はユーザーに明示確認すること。この URL は資格情報であり、会話外部に漏らさない。ログ出力にも URL そのものを含めない (必要なら末尾数文字をマスクする)。

## 使い方

### 基本の送信手順

1. 送るメッセージ本文を決める。デフォルトで以下を含めると親切:
   - 何の作業が完了/進捗したか (1〜2 行)
   - ホスト名 (このスキルは `develop` で動く想定)
   - 結果ステータス (成功/失敗/要確認)
2. `curl` で `content` フィールドに JSON エンコードして POST する。
3. HTTP ステータスが `204` (No Content) であれば成功。それ以外はレスポンスボディをユーザーに共有し、原因を調査する。

### 推奨コマンド

```bash
# webhook は gitignore 済みの設定ファイルから読む (リポジトリには含めない)
source "${XDG_CONFIG_HOME:-$HOME/.config}/discord-notify/env"
WEBHOOK_URL="$DISCORD_WEBHOOK_URL"

# MESSAGE に本文を代入 (複数行可)
MESSAGE=$(cat <<'EOF'
✅ ビルド完了: my-project
host: develop
所要時間: 14m22s
EOF
)

# jq で安全に JSON を組み立てる
jq -nc --arg content "$MESSAGE" '{content: $content}' \
  | curl -sS -w '\nHTTP %{http_code}\n' \
      -H 'Content-Type: application/json' \
      -X POST -d @- \
      "$WEBHOOK_URL"
```

`jq` が使えない環境では、本文内の `"` `\` `改行` を手動でエスケープするのではなく、Python でエスケープする:

```bash
python3 -c 'import json,sys; print(json.dumps({"content": sys.stdin.read()}))' <<< "$MESSAGE" \
  | curl -sS -H 'Content-Type: application/json' -X POST -d @- "$WEBHOOK_URL"
```

### 引数の解釈

- 位置引数のすべてをスペース連結したものを本文として扱う。
- `--title <文字列>` が与えられた場合は、本文先頭に `**<タイトル>**` を付け、改行で本文を続ける。
- メッセージ本文が空のときは送らず、ユーザーに内容を確認する。

### Discord の制限

- `content` は最大 2000 文字。超える場合は末尾を切り詰め `…(truncated)` を付ける。
- レート制限 (429) が返ったら `retry_after` 秒待機して 1 回だけ再試行する。

## 典型的な使いどころ

- 長いビルド、テスト、デプロイ、ダウンロード、バックアップなどの完了通知
- 複数タスクを並走させているときの、各タスクの完了タイミング通知
- エラー終了時の即時通知 (成功時は省略、など運用で調整)

## やってはいけないこと

- Webhook URL そのものをチャットやログに平文で出力する (URL を知っている人は誰でも投稿できる)
- ユーザーから明示の依頼がないのに通知を送る (このスキルはユーザーの明示指示でのみ起動する)
- 機密情報 (鍵、トークン、個人情報、顧客データ) を本文に含める
