---
name: resource-audit
description: develop マシンのリソース使用状況を棚卸しし、逼迫していないかを判定してレポートする。収集済みスナップショットの差分と前回比の傾向まで見る。「リソース監査レポートを出して」「リソース使用状況を確認」「サーバの負荷を見て」「メモリ/ディスクは大丈夫か」「動かしすぎていないか」などで起動。
argument-hint: "[--fresh] [--deep] [--brief]"
disable-model-invocation: false
allowed-tools: Bash, Read, Write, Edit
---

# resource-audit — リソース棚卸しレポート

`develop` のリソース使用状況を読み、**「逼迫しているか」と「放置が溜まっていないか」**を
判定してレポートする。数値の採取は済んでいる前提で、**このスキルの仕事は判断と説明**。

## 前提: 測定は Tier 1 が済ませている

`resource-audit-collect.timer` が日次 (週 1 回は `--deep`) で
`~/.local/state/resource-audit/runs/<UTC>/` にスナップショットを残している。

| パス | 内容 |
|---|---|
| `latest/summary.json` | 主要指標。**前回比を出す起点** |
| `latest/alerts.txt` | 閾値超過。`<key><TAB><説明>` |
| `latest/memory.txt` | `free` / `meminfo` / cgroup `memory.stat` / PSI の生データ |
| `latest/disk.txt` | `df -B1` / `df -i` / tmpfs / sar の I/O |
| `latest/processes.txt` | RSS 上位 30 |
| `latest/long-lived-agents.txt` | 2 日以上生きている claude / codex |
| `latest/listeners.txt` | `ss -tulpnH` の全待ち受け |
| `latest/units.txt` | failed unit と user timer 一覧 |
| `latest/herdr-agents.json` | `herdr agent list` の生 JSON |
| `latest/deep/` | `--deep` 実行時のみ: `home.txt` / `projects.txt` / `tmp.txt` / `reclaimable.txt` |
| `previous/` | 前回ラン (同じ構成) |

## 手順

### 0. 出力の信頼性を確保する

**すべての計測コマンドは `bash --noprofile --norc -c '...'` でラップする。**
既定の zsh 経由だとコマンドが未実行のまま成功表示されたり偽の出力が混入する
(`troubleshooting/claude-code-bash-output-unreliable.md`)。

### 1. スナップショットを用意する

```bash
bash --noprofile --norc -c 'S=~/.local/state/resource-audit; ls -1t $S/runs | head -3; echo "--- latest ---"; readlink $S/latest; stat -c %y $S/latest/summary.json'
```

- 24 時間以上古い、または存在しない → `~/dotfiles/scripts/resource-audit/collect.sh` を実行する
- 引数 `--fresh` が渡された → 古さに関わらず実行する
- 引数 `--deep` が渡された、またはディスクの話が主題 → `collect.sh --deep` で実行する

`collect.sh` を自分で走らせた場合、その回が `latest` になり直前が `previous` になる。

### 2. 数値を読む

```bash
bash --noprofile --norc -c 'S=~/.local/state/resource-audit; jq . $S/latest/summary.json; echo "=== previous ==="; jq . $S/previous/summary.json 2>/dev/null'
```

**必ず previous と比べる。** 「64%」だけでは増加中か横ばいか分からない。
`summary.json` は同じキー構成なので、差が出た項目を拾って傾向として書く。

判定の目安 (`resources/README.md` のベースラインと同じ):

| 指標 | 見方 |
|---|---|
| `pressure_full_avg300` | **`full` が継続的に 0 以外なら本当に詰まり始めている。`some` だけなら正常** |
| `swap.used_bytes` | MB 級に増える / `sar -B` の `pswpin/s` ≠ 0 ならメモリ不足の初期兆候 |
| `mem.anon_bytes` | 実使用。`systemd-cgtop -m` の `user.slice` は page cache 込みで過大なので使わない |
| `mem.shmem_bytes` | **`/tmp` が tmpfs なので、ここに置いたものがそのまま RAM を食う** |
| `disk.root_use_pct` | 85% 超で `target/` と `node_modules/` を掃除する |
| `agents.oldest_days` | 長いほど「開いたまま忘れている」セッション |
| `wildcard_listeners` | **`0.0.0.0` の見覚えのないポート = 忘れられた開発サーバ**。許可済みは `wildcard-allow.txt` |

### 3. レポートを書く

**結論を先に、数値は表で、指摘は優先度順に。** 構成:

1. **結論 1〜2 文** — 逼迫しているか否か。していないなら断定する (曖昧に濁さない)
2. **主要指標の表** — 実測 / 容量 / 判定。前回から動いた項目は差分も書く
3. **メモリの主役** — 何が食っているか (通常は claude と MCP の node)
4. **指摘** — `alerts.txt` + 自分で気付いたものを優先度順。各項目に「なぜ問題か」を 1 行
5. **ディスク** — `--deep` のときだけ内訳と再生成可能な量

書き方の原則:

- **リソース逼迫と「放置」を区別する。** 大抵は前者に問題はなく後者に溜まっている。
  その場合は「リソースは問題ない」と明言したうえで放置分を挙げる
- 数値は実測値をそのまま書く。丸めすぎない
- 「〜かもしれません」を重ねない。測ったことは断定し、測っていないことは測っていないと書く
- `alerts.txt` に出ていない異常に気付いたら、それも書く (閾値は網羅ではない)

### 4. 対処は提案までにする

**実行してよいもの** (求められたら):

- 追加の計測・調査コマンド
- `resources/README.md` や関連ドキュメントの更新

**必ずユーザーの明示的な承認を取るもの**:

- プロセスの kill / サービスの停止 (`0.0.0.0` の放置サーバを含む)
- ファイルやディレクトリの削除 (`/tmp` の掃除、`target/` `node_modules/` の削除)
- 再起動
- **herdr のペイン / ワークスペースを閉じる操作** — 隣のペインを巻き込みうる。人がやる

削除を提案するときは、**対象・サイズ・最終更新日・再生成方法**をセットで出す。

## 知見が出たら記録する

このマシンの事実が新たに分かったら、その場で `~/workspace/machine` の該当 `.md` を
更新する (規約は同リポジトリの `CLAUDE.md`)。リソース関連は `resources/README.md`。
ベースラインの数値が現実と乖離したら古い記述を訂正する。

## 関連

| 対象 | ドキュメント |
|---|---|
| ベースラインと棚卸し手順 | `~/workspace/machine/resources/README.md` |
| 収集スクリプト | `~/dotfiles/scripts/resource-audit/collect.sh` |
| 週次でこのスキルを起動する側 | `~/dotfiles/scripts/resource-audit/report.sh` |
| 常駐サービス個別 | `machine/services/` / `machine/dev/agent-web/` |
| 通知 | `discord-notify` スキルと同じ webhook |
