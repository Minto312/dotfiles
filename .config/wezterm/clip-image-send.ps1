# 手元 (Windows) のクリップボードの画像を PNG にして develop に送り、develop 上の絶対パスを標準出力に 1 行で出す。
# wezterm の Alt+V (image_paste.lua) から pwsh -STA -File で呼ぶ。クリップボードは読むだけで、書き換えない。
#
# 終了コード:
#   0  送った。標準出力は develop 上の絶対パス
#   2  クリップボードに画像が無い。標準出力は理由
#   1  送れなかった。標準出力は理由
param(
  [string]$SshHost = 'develop',
  # develop の $HOME からの相対パス。/tmp は tmpfs (メモリ) なので使わない
  [string]$RemoteDir = '.cache/clip-images',
  [int]$TimeoutSec = 20
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

function Fail([int]$code, [string]$msg) {
  [Console]::Out.WriteLine($msg)
  exit $code
}

# クリップボードの画像を PNG のバイト列で返す。画像が無ければ $null。
function Get-ClipboardPng {
  Add-Type -AssemblyName System.Windows.Forms, System.Drawing
  # 別のアプリがクリップボードを開いている間は読めないので、少し待って読み直す
  $data = $null
  for ($i = 0; $i -lt 5; $i++) {
    try { $data = [Windows.Forms.Clipboard]::GetDataObject(); break }
    catch { Start-Sleep -Milliseconds 100 }
  }
  if (-not $data) { return $null }

  # PNG の形式があれば、そのまま使う (透過を保つ。Win+Shift+S やブラウザのコピーが置く)
  if ($data.GetDataPresent('PNG')) {
    $png = $data.GetData('PNG')
    if ($png -is [IO.MemoryStream]) { return $png.ToArray() }
  }
  # 無ければビットマップ (DIB) を PNG にする
  if ([Windows.Forms.Clipboard]::ContainsImage()) {
    $img = [Windows.Forms.Clipboard]::GetImage()
    if ($img) {
      $ms = [IO.MemoryStream]::new()
      try { $img.Save($ms, [Drawing.Imaging.ImageFormat]::Png); return $ms.ToArray() }
      finally { $img.Dispose(); $ms.Dispose() }
    }
  }
  return $null
}

try { $bytes = Get-ClipboardPng }
catch { Fail 1 "クリップボードを読めませんでした: $($_.Exception.Message)" }
if (-not $bytes) { Fail 2 'クリップボードに画像がありません' }

# 時刻 (ミリ秒まで) と乱数で、名前が重ならないようにする
$name = 'clip-{0}-{1}.png' -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'), [guid]::NewGuid().ToString('N').Substring(0, 6)
# develop で 1 回の ssh で、ディレクトリを作り、標準入力を書き、絶対パスを返す。持ち主だけが読める権限にする
$remote = "umask 077 && d=`"`$HOME/$RemoteDir`" && mkdir -p `"`$d`" && cat > `"`$d/$name`" && printf '%s\n' `"`$d/$name`""

$psi = [Diagnostics.ProcessStartInfo]::new('ssh.exe')
foreach ($a in @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', $SshHost, $remote)) { $psi.ArgumentList.Add($a) }
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true

try {
  $p = [Diagnostics.Process]::Start($psi)
  $outTask = $p.StandardOutput.ReadToEndAsync()
  $errTask = $p.StandardError.ReadToEndAsync()
  # ssh が先に終わると (接続できないなど) 書き込みが失敗する。理由は ssh の標準エラーで出すので、ここでは止めない
  try { $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length); $p.StandardInput.Close() }
  catch { }
  if (-not $p.WaitForExit($TimeoutSec * 1000)) {
    $p.Kill()
    Fail 1 "${SshHost} へ送れませんでした: ${TimeoutSec} 秒で終わりませんでした"
  }
  $out = $outTask.Result.Trim()
  # ssh が毎回出す警告 (post-quantum の鍵交換) は理由にしない
  $err = ($errTask.Result -split "`r?`n" | Where-Object { $_ -and $_ -notmatch 'post-quantum|store now|upgraded' }) -join ' '
}
catch { Fail 1 "${SshHost} へ送れませんでした: $($_.Exception.Message)" }

if ($p.ExitCode -ne 0 -or -not $out.StartsWith('/')) {
  Fail 1 "${SshHost} へ送れませんでした (ssh の終了コード $($p.ExitCode)): $err"
}
[Console]::Out.WriteLine($out)
exit 0
