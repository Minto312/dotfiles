---
name: lenovo
description: ユーザーの手元の Windows 機 lenovo (ThinkPad X13 Gen 5) でコマンドを動かす・調べる・ファイルを送る・ウィンドウを操作する・画面を撮るときの手順と決まり。`ssh lenovo` (Session 0) と `lenovo-interactive-run` (利用者のデスクトップの Session 1) の使い分け、利用者の画面のフォーカスを奪わない方法、PowerShell (pwsh 7) の書き方と罠、昇格 (UAC)、ssh を抜けると起動したプロセスが終わる件。「lenovo で」「Windows 側で」「手元の PC で」と言われたとき、ssh lenovo・ssh lenovo-interactive・scp lenovo を使う前、winget・レジストリ・スケジュールタスク・ウィンドウの操作をする前に読む。Office の変換は office-render、ブラウザは browser、develop のポートを手元に通すのは lenovo-tunnel スキル。
---

# lenovo — 手元の Windows 機でコマンドを動かす

lenovo は、ユーザーが今使っている Windows 11 の ThinkPad である。develop から ssh で入れる。**ユーザーが作業している画面がある機械**なので、画面に何かを出す操作は、ユーザーの作業を邪魔しないかを先に考える。

## 経路は 2 つ。目的で選ぶ

| 経路 | 動く場所 | 昇格 | 使う場面 |
|---|---|---|---|
| `ssh lenovo '<PowerShell>'` | Session 0 (サービス。誰も見ていない画面) | している | ファイル、レジストリ、CLI、サービス、スケジュールタスクの登録、DISM 系のコマンドレット。**利用者の画面には何も出ない** |
| `lenovo-interactive-run '<PowerShell>'` | Session 1 (利用者のデスクトップ) | していない | winget のインストール・AppX、ウィンドウの列挙と操作 (`MainWindowHandle`・`CloseMainWindow()`)、画面を撮る、利用者の画面にアプリを開く |
| `scp <ファイル> lenovo:C:/…` (`lenovo-interactive:` でもよい) | — | — | ファイルの受け渡し。どちらでもウィンドウは出ない |

- **迷ったら `ssh lenovo`。** Session 1 が要るのは、表の 2 行目の場面だけである
- 🔴 **`ssh lenovo-interactive "<コマンド>"` (端末なし) を直接使わない。** 実行のたびに利用者の画面にコンソールのウィンドウが開き、フォーカスを奪う (2026-11-15 にユーザーから苦情があった)。OpenSSH 9.5 for Windows が、pwsh に見えるコンソールを作るためである
- `lenovo-interactive-run` は端末付きで接続するので、ウィンドウが出ない。出力 (標準出力と標準エラーをまとめたもの) をコマンドが終わってから返し、コマンドの終了コードで終わる。接続できなければ 255。1 回に 2 秒ほどかかる
  - `lenovo-interactive-run - < script.ps1` で、標準入力のスクリプト (12 KB 程度まで) を実行する
- `ssh lenovo` の標準エラーには、毎回 `** WARNING: connection is not using a post-quantum key exchange algorithm.` などの 3 行が出る。無害なので、`grep -v -i -E 'post-quantum|store now|upgraded'` で落とす
- 一時ファイルは `C:/Users/karinto/AppData/Local/Temp/` に置き、使い終わったら消す

## PowerShell の書き方

- 既定のシェルは、どちらの経路も **pwsh 7**。`powershell` と書くと Windows PowerShell 5.1 が動く
- 🔴 **引用符や `$` を含むものは、`-EncodedCommand` か .ps1 のファイルにする。** develop の bash、ssh、pwsh の 3 段で引用符が解釈されるので、そのまま書くと崩れやすい
  - `-EncodedCommand`: `enc=$(printf '%s' "$ps" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)` で作り、`ssh lenovo "pwsh -NoProfile -EncodedCommand $enc"` で渡す
  - ファイル: Write ツールで develop に .ps1 を書き、scp で送って `pwsh -NoProfile -ExecutionPolicy Bypass -File <パス>` で動かす
  - `lenovo-interactive-run` は中で `-EncodedCommand` にするので、引数には PowerShell をそのまま書けばよい
- 🔴 Claude の Bash で `bash -c '…'` の中に PowerShell の `'…'` を書くと、単一引用符が黙って消える。長いものは Write ツールでファイルに書く
- **日本語を返すときは、スクリプトの最初で `[Console]::OutputEncoding = [Text.Encoding]::UTF8` にする。** ssh 越しのコンソールは CP932 のままなので、`ssh lenovo` の日本語の出力やエラーは化ける (`lenovo-interactive-run` では化けなかった)
- 進み具合の表示が `#< CLIXML …` として標準エラーに出る。`$ProgressPreference = 'SilentlyContinue'` で止める
- pwsh の `ls`・`rm`・`cat`・`ps`・`kill` は、Unix の名前を付けたエイリアスで、オプションは PowerShell のものである。`rm -rf` は通らず、`rm -Recurse -Force` と書く
- 文字列の中の `"$h:8080"` は、`$h:8080` という名前の変数として読まれて空になる。`"${h}:8080"` と書く
- 5.1 (`powershell`) で日本語を含む .ps1 を動かすときは、BOM 付きの UTF-8 にする (5.1 は BOM の無いファイルを CP932 として読む)

## ssh を抜けると、そこで起動したプロセスは終わる

- Windows の sshd は接続ごとに Job Object を作り、接続が終わると子のプロセスをまとめて終わらせる。`Start-Process` で起動したものも巻き込まれる
- 動かし続けたいもの (常駐するもの、GUI のアプリ) は、スケジュールタスク (`New-ScheduledTaskPrincipal -LogonType Interactive`) から起動する
- `Start-Process` の直後に pwsh が終わると、起動したプロセスが仕事を終える前に殺されることがある (Chrome に URL を渡す処理で起きた)

## 昇格 (UAC)

- `ssh lenovo` は昇格している。`lenovo-interactive-run` は昇格していない
- **Session 1 で昇格が要るもの** (machine scope のインストールやアンインストールなど) は、`ssh lenovo` から `Register-ScheduledTask` で `-LogonType Interactive -RunLevel Highest` のタスクを登録して動かす。UAC を出さずに、Session 1 で昇格して動く。`lenovo-interactive-run` からは、このタスクを登録できない (`Access is denied`)
- user scope の winget の操作は、昇格すると `0x8A15007D` で拒否される。`lenovo-interactive-run` から昇格せずに動かす
- `lenovo-interactive-run` から昇格が要るインストーラを動かすと、利用者の画面に UAC が出て、人が承認するまで止まる
- Session 0 で UI を出しうるインストーラ (Chromium 系のアンインストーラなど) を動かすと、誰も見ていない画面でダイアログを出して止まる。上の昇格タスクを使う

## lenovo-interactive が通らないとき

内側の sshd は、トレイのアプリ `lenovo-interactive-tray.exe` が画面を出さずに起動して見張る。アプリは、スケジュールタスク `LenovoInteractiveSshd` が起動する。

- sshd が止まると、アプリが 5 秒後に起動し直す。続けてすぐに止まると、間を 10・20・40・80・160・300 秒と延ばす
- アプリが終わると、sshd も終わる。タスクは起動し直さない
- アプリの場所は `C:\Users\karinto\AppData\Local\lenovo-interactive-sshd\` である。同じフォルダの `tray.log` に、sshd の起動と終了 (終了コード、動いた秒数) が書かれる

通らないとき (`Connection closed` で、`lenovo-interactive-run` が 255 で終わる) は、次の順に見る。

1. タスクの状態を見る。`Ready` なら、アプリは終わっている。タスクを起動する
2. タスクが動いていれば、`tray.log` を読み、sshd が止まった理由と、起動し直すのを待っているかを見る

```bash
ssh lenovo 'Get-ScheduledTask -TaskName LenovoInteractiveSshd | Select-Object State'
ssh lenovo 'Start-ScheduledTask -TaskName LenovoInteractiveSshd'
ssh lenovo '[Console]::OutputEncoding = [Text.Encoding]::UTF8; Get-Content -Encoding UTF8 -Tail 20 C:/Users/karinto/AppData/Local/lenovo-interactive-sshd/tray.log'
```

- 🔴 アプリのアイコンは、ユーザーの画面の通知領域にある。緑は sshd が動いている、黄は起動し直すのを待っている、赤は続けて 3 回以上すぐに止まったことを表す。Claude は、メニューの「終了する」を押さない。アプリを `Stop-Process` などで止めない
- ユーザーがログオンしていない間は使えない。これは正常である

## 画面を撮る

画面全体ではなく、対象のアプリのウィンドウだけを撮る。このスキルの `scripts/capture-window.ps1` を使う (`PrintWindow` で撮るので、GPU で描く wezterm も撮れる)。

```bash
d=~/.claude/skills/lenovo/scripts
T=C:/Users/karinto/AppData/Local/Temp
scp -q "$d/capture-window.ps1" "lenovo-interactive:$T/"
lenovo-interactive-run "& $T/capture-window.ps1 -ProcessName wezterm-gui"   # 保存したパスを表示する
scp -q "lenovo-interactive:$T/capture-wezterm-gui-0.png" <scratchpad>/
lenovo-interactive-run "Remove-Item $T/capture-window.ps1, $T/capture-*.png"
```

- ウィンドウが無ければ (Session 0 で動かした場合も含む)、1 で終わる
- 字の大きさや細部は、縮小した画像では判断できない。Pillow (`uv run --no-project --with pillow python -I …`) で、元の解像度のまま切り出して拡大して見る
- 撮った画像には、ユーザーの作業の内容が写る。scratchpad の外に置かない。lenovo 側の画像は消す

## ユーザーの邪魔をしない

- 利用者の画面にウィンドウを出す操作 (`Start-Process` でアプリを起動する、テスト用のウィンドウを開く) は、それが目的のときだけにする。コンソールのアプリ (`cmd.exe` など) を `Start-Process` すると、そのウィンドウもフォーカスを奪う
- 利用者のアプリを終わらせるときは、`Stop-Process` ではなく `CloseMainWindow()` を使う。×ボタンを押したのと同じ経路なので、保存などの終了処理が走る

```bash
lenovo-interactive-run '$p = Get-Process -Id <pid>; $p.CloseMainWindow(); $p.WaitForExit(20000)'
```

## 詳しい記録

machine ワークスペース (`~/workspace/machine/`) の次の文書に、実測と経緯がある。

- `dev/lenovo-interactive-ssh.md` — 2 つの経路、フォーカスを奪う原因と `lenovo-interactive-run` の作り、昇格の組み合わせ、内側の sshd が止まる件
- `dev/powershell.md` — pwsh 7 と 5.1、文字コード、エイリアスの罠
- `dev/winget/README.md` — winget を ssh 越しに使うときの制約
- `dev/lenovo-browser.md` — Chrome をスケジュールタスクから起動する理由
