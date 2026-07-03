---
name: lllm
description: 自宅 LAN 内のローカル LLM サーバ (lllm VM, Ollama on GTX 1070) を呼び出して 1 回応答を得る、または会話する。「lllm に聞いて」「ローカル LLM で生成」「qwen に質問」「ollama 呼んで」「ローカルで考えて」などで起動。Anthropic に投げる前に手元で軽く回したい問い合わせや、機密で外に出したくないテキスト処理（要約・整形・翻訳・分類）に向く。
argument-hint: "<prompt> | models | embed <text>... | --model <name> <prompt> | --system <msg> <prompt>"
disable-model-invocation: false
allowed-tools: Bash
---

# ローカル LLM 呼び出しスキル (lllm)

`http://lllm:11434` で動いている Ollama を、**OpenAI 互換 API** 経由で叩く。スキルは Bash + curl + jq だけで自己完結（このマシンの develop CT に jq が無ければ apt install を促す）。

このスキルは **「Claude が自分で呼ぶ」** か **「ユーザーが /lllm で呼ぶ」** の両方を想定する:

- 軽い分類・抽出・翻訳・要約をローカルで済ませたい時に Claude 自身が delegation 用に呼ぶ
- ユーザーが `/lllm <prompt>` でちょっと聞きたい時に直叩き

## エンドポイント

- Base URL: `http://lllm:11434`
- 認証なし（LAN ファイアウォールで `192.168.2.0/24` のみ受け付け）
- 既定モデル: `hf.co/mmnga/Gemma-2-Llama-Swallow-9b-it-v0.1-gguf:Q4_K_M`（日本語品質最高、創作・敬語・要約に強い、16 tok/s）
- 速度・汎用 JP 用 Secondary: `lucas2024/llama-3-swallow-8b-v0.1:q5_k_m`（29 tok/s）
- 英語タスク・速度重視: `qwen2.5:7b-instruct-q4_K_M`（最速 36 tok/s）
- 利用可能モデル一覧: `http://lllm:11434/v1/models` または `/api/tags`

到達できないとき（ホスト名解決失敗・ufw 拒否・VM 停止）は早めにユーザーへ報告し、勝手にリトライを続けない。

## 引数の解釈

スキル起動時に渡される `<args>` を以下の優先順で解釈する:

1. `models` 単独 → モデル一覧表示
2. `embed <text> [<text>...]` → 埋め込み + ペアワイズコサイン類似度
3. `--model <name>` → 以降のプロンプトに対し既定モデルを上書き
4. `--system <msg>` → system プロンプトを追加（既定では system 無し）
5. `--temperature <0..2>` → 生成温度（既定 0.7）
6. それ以外（最も多い）→ すべて連結して 1 回の **gen** プロンプトとして送信

複数の `--xxx` フラグは混在可。フラグが消費した残りが空文字なら「プロンプトが空」とユーザーに確認してから送る（デフォルト動作で勝手にモデル呼び出しを開始しない）。

## 推奨実装パターン (Bash)

`jq` で JSON を組み立て、curl で叩き、結果を抽出して **そのまま標準出力に流す**（Claude はその出力を読んでユーザーに返す）。

### 1) 一発生成 (gen)

```bash
LLLM_HOST="${LLLM_HOST:-http://lllm:11434}"
MODEL="${LLLM_MODEL:-hf.co/mmnga/Gemma-2-Llama-Swallow-9b-it-v0.1-gguf:Q4_K_M}"
SYSTEM=""   # 必要なら --system で上書き
TEMP="0.7"
PROMPT="ここにユーザーの全プロンプト"

# messages 配列を組み立てる
if [[ -n "$SYSTEM" ]]; then
  msgs=$(jq -nc --arg s "$SYSTEM" --arg u "$PROMPT" \
    '[{role:"system",content:$s},{role:"user",content:$u}]')
else
  msgs=$(jq -nc --arg u "$PROMPT" '[{role:"user",content:$u}]')
fi

payload=$(jq -nc --arg m "$MODEL" --argjson ms "$msgs" --arg t "$TEMP" \
  '{model:$m, messages:$ms, temperature:($t|tonumber), stream:false}')

resp=$(curl -sS --max-time 120 "$LLLM_HOST/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d "$payload")

# 応答テキストとメタデータを取り出す
echo "$resp" | jq -r '.choices[0].message.content // (.error // "(no response)")'
echo "---"
echo "$resp" | jq -r '"model=\(.model)  prompt_tokens=\(.usage.prompt_tokens)  completion_tokens=\(.usage.completion_tokens)  total_tokens=\(.usage.total_tokens)"'
```

### 2) モデル一覧

```bash
curl -sS "$LLLM_HOST/v1/models" | jq -r '.data[].id' | sort
```

または Ollama ネイティブの `/api/tags` でサイズや更新時刻も欲しい時:

```bash
curl -sS "$LLLM_HOST/api/tags" \
  | jq -r '.models[] | "\(.name)\t\(.size)\t\(.modified_at)"' \
  | column -t -s $'\t'
```

### 3) 埋め込み + コサイン類似度

```bash
EMBED_MODEL="${LLLM_EMBED_MODEL:-nomic-embed-text}"
# 配列にして送る
inputs=$(jq -nc --args '$ARGS.positional' --args "テキスト1" "テキスト2" "...")
# (実装メモ: 引数の数だけ jq で配列にする — 下記 helper 関数も可)

curl -sS "$LLLM_HOST/v1/embeddings" \
  -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg m "$EMBED_MODEL" --argjson i "$inputs" '{model:$m, input:$i}')" \
  | jq '.data[].embedding'
```

> 詳細な類似度行列が欲しいときは `/home/karinto/workspace/lllm/clients/python/lllm.py embed ...` を使う方が早い（このマシン上にあるなら）。

## 振る舞い指針

- **応答は短く**: ユーザーが指定しない限り、`max_tokens` 等は付けない（モデル既定に任せる）。Claude 自身が delegation で呼ぶ場合のみ、コスト/時間を見て `max_tokens` を絞ってよい
- **エラーハンドリング**: `curl` の終了コード ≠ 0、HTTP 4xx/5xx、`.error` フィールド存在のいずれかが起きたら **リトライ前にユーザーへ通知**
- **ホスト名解決**: `lllm` がダメなら IP 直 (`http://192.168.2.x:11434`) を `LLLM_HOST` で上書きしてもらう
- **ストリーム**: スキル経由ではブロッキング (`stream:false`) を既定とする。長文生成で待たせたくない場合のみ `stream:true` + SSE 受信処理を書く（コスト見合いで）

## やってはいけないこと

- LLLM_HOST に外部の Anthropic / OpenAI 系 URL を勝手に向ける（このスキルは LAN 内 Ollama 専用）
- `--system` を使って勝手にユーザーになりすますような system プロンプトを差し込む（system はユーザー指定のみ）
- 連続失敗時に黙ってリトライし続ける（最大 1 回再試行で止め、状況をユーザーに見せる）
- ユーザー入力を改変・拡張せずにそのまま送る方針を破る（要約や付加が要るときは事前にユーザー確認）

## 想定する典型コール

```
/lllm 次の文を 50 字以内に要約して: 〜
/lllm models
/lllm --model llama3.1:8b-instruct-q4_K_M Reply with one number: 2+2
/lllm --system 「あなたは厳格な校正者です」 この文の誤りを 3 つ列挙して: 〜
/lllm embed "東京から大阪まで新幹線で行く" "Shinkansen from Tokyo to Osaka"
```

## 参考

- 構築背景: `/home/karinto/workspace/lllm/`（VM のセットアップ・cloud-init テンプレ・ベンチ・既製クライアント）
- このスキルは Bash + curl + jq のみ。Python CLI が必要なら `/home/karinto/workspace/lllm/clients/python/lllm.py` を使うが、スキル本体は依存させない
