# Capture the main window(s) of a process to PNG, without touching other windows.
# Run on lenovo in Session 1 (lenovo-interactive-run). Prints the saved paths.
#   & capture-window.ps1 -ProcessName wezterm-gui [-OutDir $env:TEMP]
# Output: <OutDir>\capture-<ProcessName>-<n>.png  (n = 0, 1, ... per window)
param(
  [Parameter(Mandatory = $true)][string]$ProcessName,
  [string]$OutDir = $env:TEMP
)
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class LenovoCapture {
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint f);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L; public int T; public int R; public int B; }
}
"@
[LenovoCapture]::SetProcessDPIAware() | Out-Null
$procs = @(Get-Process $ProcessName -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 })
if ($procs.Count -eq 0) {
  Write-Output "no window for process '$ProcessName' (Session 1 is required: use lenovo-interactive-run)"
  exit 1
}
$i = 0
foreach ($p in $procs) {
  $h = $p.MainWindowHandle
  $r = New-Object LenovoCapture+RECT
  [LenovoCapture]::GetWindowRect($h, [ref]$r) | Out-Null
  $w = $r.R - $r.L; $ht = $r.B - $r.T
  $bmp = New-Object System.Drawing.Bitmap $w, $ht
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $hdc = $g.GetHdc()
  # 2 = PW_RENDERFULLCONTENT (needed for windows drawn by the GPU, such as WezTerm)
  [LenovoCapture]::PrintWindow($h, $hdc, 2) | Out-Null
  $g.ReleaseHdc($hdc); $g.Dispose()
  $out = Join-Path $OutDir "capture-$ProcessName-$i.png"
  $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
  Write-Output "saved $out (pid=$($p.Id) size=${w}x${ht} dpi=$([LenovoCapture]::GetDpiForWindow($h)))"
  $i++
}
