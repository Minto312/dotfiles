---
name: browser
description: エージェントがブラウザを使うときの決まり (Playwright MCP がどの Chrome に繋がるか・繋がらないときに旧方式へ切り替えないこと・タブとログインとファイル添付の扱い・旧方式を使ってよい場面)。どのワークスペースでも、Playwright MCP の browser_* ツールを初めて呼ぶ前、Web ページを開く・操作する・人にログインしてもらう・画面を撮る前に読む。「ブラウザで開いて」「画面を操作して」「ログインして」「スクショを撮って」「フォームに入力して」などで起動。
---

# browser — エージェントがブラウザを使うときの決まり

ここには守ることだけを書きます．仕組み・実測・経緯は `~/workspace/machine/dev/lenovo-browser.md` にあります．

## 1. Playwright MCP の行き先

- Playwright MCP (`browser_*` ツール) は，lenovo の普段の Chrome の `Profile 15` に，Playwright 拡張機能を通して繋がります (2026-11-09 からの既定)．
- 最初にツールを呼んだときに，lenovo に新しいウィンドウが開いて繋がります．`lenovo-browser up` などの準備は要りません．
- エージェントが触れるのは，そのセッション用のタブグループのタブだけです．人のタブは見えません．
- `Profile 15` のログイン状態はすべて使えます．触れるタブは絞られていますが，使える権限は絞られていません．
- MCP の行き先はセッションの起動時に決まります．2026-11-09 より前に起動したセッションの MCP は，旧方式 (CDP) のまま動いています．

## 2. 繋がらないとき

- `Playwright extension did not connect within 30s` が出たら，同じツールをもう 1 回だけ呼び直してください．
- 2 回続けて失敗したら，人に伝えて指示を待ってください．
- 🔴 **自分の判断で旧方式に切り替えないでください．**旧方式とは，`lenovo-browser up`，shared-browser，`127.0.0.1:9333` や `127.0.0.1:9222` への CDP 接続，playwright-core の `connectOverCDP` を使うスクリプトのことです．
  - 旧方式の Chrome は別のプロファイルなので，ログイン状態が違います．開いたタブはタブグループにも入りません．
  - 2026-11-15 に，切り替えたセッションが，ログインしていないプロファイルに GitHub のログイン画面を開きました．人からは，どこでログインすればよいのか分からない状態になりました．
- lenovo がスリープ中やログオフ中のときは，lenovo の Chrome は使えません．そのことを人に伝えてください．

## 3. 旧方式を使ってよい場面

- 人が旧方式を使うよう指示したとき．
- そのワークスペースのスキルや CLAUDE.md が，その作業に shared-browser を指定しているとき．
- shared-browser を使うときも，Playwright MCP は shared-browser に繋がりません．shared-browser のページは，playwright-core の `connectOverCDP` で操作してください．

## 4. ログインの要らない公開ページ

- 公開ページを見る・画面を撮るだけなら，develop の Chrome を headless で動かしてかまいません．人の画面にウィンドウが開きません．
- 例: `google-chrome --headless=new --window-size=1280,900 --screenshot=<出力先> <URL>`，または playwright-core から `executablePath: '/usr/bin/google-chrome'` で起動する．

## 5. タブの扱い

- 新しい用事は，`browser_tabs` の `new` でタブを開いてから `browser_navigate` してください．
- 裏に回ったタブでは，`browser_click` が「visible 待ち」で止まります．`browser_tabs` の `select` でそのタブを選び直してから操作してください．
- 人がタブグループを別のウィンドウへ移すと，接続が切れます．次の呼び出しで新しいグループから繋ぎ直すので，それまでのタブは見えなくなります．
- セッションが終わっても，lenovo のウィンドウは残ります．閉じるのは人です．

## 6. 人にログインしてもらうとき

- ログインは，エージェントのタブグループのタブでしてもらってください．
- ログインしてもらう間は，ブラウザの操作と監視 (定期的なタブ一覧の取得を含む) をすべて止めてください．ほかのエージェントにも止めさせてください．
- ログインが済んだかどうかは，本人の返事を待って判断してください．

## 7. ファイルを添付するとき

- `browser_file_upload` は develop のパスを Chrome に渡すので，lenovo の Chrome からは読めません．
- ファイルを `scp` で lenovo に置き，`browser_run_code_unsafe` で `DOM.setFileInputFiles` に Windows のパスを渡してください．
- この方法は CDP 方式のときに通りました．拡張機能を通した接続で通るかは，まだ確かめていません．
