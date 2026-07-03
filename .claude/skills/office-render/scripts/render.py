#!/usr/bin/env python3
"""
office-render: Render Office documents to images/PDF using the real Microsoft
Office (PowerPoint / Word / Excel) on the Windows machine reachable via SSH.

Flow (all automated):
  1. Detect file type from extension.
  2. scp the source file to a per-job work dir on the Windows host.
  3. Drive Office via COM (PowerShell, sent as -EncodedCommand so no quoting hell).
     - .ppt/.pptx  -> one PNG per slide (native, high fidelity) and/or a PDF.
     - .doc/.docx  -> PDF; PNG pages are rasterised locally from that PDF (poppler).
     - .xls/.xlsx  -> PDF (fit-to-width); PNG pages rasterised locally.
  4. scp results back to a local output directory.
  5. Clean up the remote work dir.
  6. Print the local output paths (Claude then Reads the PNG/PDF).

Why Windows COM instead of LibreOffice: fidelity. Real Office renders the exact
fonts, gradients, logos and layout the author sees. LibreOffice substitutes fonts
and reflows subtly.

Requires: `ssh <host>` working (default host: lenovo), Office installed on the host,
poppler-utils (pdftoppm) locally for docx/xlsx PNG output.
"""

import argparse
import base64
import os
import re
import shutil
import subprocess
import sys
import time

# ssh/scp host alias: reject anything that could be parsed as an ssh option/flag.
HOST_RE = re.compile(r"^[A-Za-z0-9._-]+$")
# our own render artifacts, safe to delete from a user-supplied --out dir on re-run.
OUR_OUTPUT_RE = re.compile(r"^(slide-\d+\.png|page-\d+\.png)$")

# ext -> (com_app, native_png)
#   native_png=True  -> the app itself exports PNG per slide (PowerPoint only)
#   native_png=False -> we export PDF then rasterise locally with pdftoppm
APP_BY_EXT = {
    ".ppt":  ("powerpoint", True),
    ".pptx": ("powerpoint", True),
    ".pps":  ("powerpoint", True),
    ".ppsx": ("powerpoint", True),
    ".doc":  ("word", False),
    ".docx": ("word", False),
    ".rtf":  ("word", False),
    ".xls":  ("excel", False),
    ".xlsx": ("excel", False),
    ".csv":  ("excel", False),
}


def log(msg):
    print(f"[office-render] {msg}", file=sys.stderr, flush=True)


def die(msg, code=1):
    print(f"[office-render] ERROR: {msg}", file=sys.stderr, flush=True)
    sys.exit(code)


def run(cmd, **kw):
    """Run a command, return CompletedProcess (text captured)."""
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def ssh_capture(host, remote_cmd, timeout=300):
    return run(["ssh", "-o", "BatchMode=yes", host, remote_cmd], timeout=timeout)


def scp(src, dst, recursive=False, timeout=600):
    cmd = ["scp", "-q", "-o", "BatchMode=yes"]
    if recursive:
        cmd.append("-r")
    cmd += [src, dst]
    return run(cmd, timeout=timeout)


def build_powershell(app, src_win, want_pdf, pdf_win, want_png, png_dir_win, width):
    """Return a PowerShell script string for the given Office app."""
    header = (
        "$ErrorActionPreference='Stop'\n"
        "$ProgressPreference='SilentlyContinue'\n"
        "try {\n"
    )
    footer = (
        "  Write-Output 'RENDER_OK'\n"
        "} catch {\n"
        "  Write-Output ('RENDER_ERR ' + $_.Exception.Message)\n"
        "  exit 1\n"
        "}\n"
    )

    if app == "powerpoint":
        body = f'''
  $app = New-Object -ComObject PowerPoint.Application
  try {{
    $pres = $app.Presentations.Open('{src_win}', $true, $false, $false)
'''
        if want_png:
            body += f'''
    $wpt = $pres.PageSetup.SlideWidth
    $hpt = $pres.PageSetup.SlideHeight
    $tw = {width}
    $th = [int][math]::Round($tw * $hpt / $wpt)
    if (-not (Test-Path '{png_dir_win}')) {{ New-Item -ItemType Directory -Path '{png_dir_win}' | Out-Null }}
    $i = 0
    foreach ($s in $pres.Slides) {{
      $i++
      $name = 'slide-{{0:D3}}.png' -f $i
      $s.Export((Join-Path '{png_dir_win}' $name), 'PNG', $tw, $th)
    }}
    Write-Output ("SLIDES=" + $pres.Slides.Count)
'''
        if want_pdf:
            body += f"    $pres.SaveAs('{pdf_win}', 32)\n"
        body += '''    $pres.Close()
  } finally {
    $app.Quit()
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($app) | Out-Null
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
  }
'''
    elif app == "word":
        # Word always produces a PDF; PNG (if asked) is rasterised locally.
        body = f'''
  $app = New-Object -ComObject Word.Application
  $app.Visible = $false
  $app.DisplayAlerts = 0
  try {{
    $doc = $app.Documents.Open('{src_win}', $false, $true)
    $doc.ExportAsFixedFormat('{pdf_win}', 17)
    Write-Output ("PAGES=" + $doc.ComputeStatistics(2))
    $doc.Close($false)
  }} finally {{
    $app.Quit()
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($app) | Out-Null
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
  }}
'''
    elif app == "excel":
        body = f'''
  $app = New-Object -ComObject Excel.Application
  $app.Visible = $false
  $app.DisplayAlerts = $false
  try {{
    $wb = $app.Workbooks.Open('{src_win}', 0, $true)
    foreach ($ws in $wb.Worksheets) {{
      $ws.PageSetup.Zoom = $false
      $ws.PageSetup.FitToPagesWide = 1
      $ws.PageSetup.FitToPagesTall = $false
    }}
    $wb.ExportAsFixedFormat(0, '{pdf_win}')
    $wb.Close($false)
  }} finally {{
    $app.Quit()
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($app) | Out-Null
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
  }}
'''
    else:
        raise ValueError(f"unknown app {app}")

    return header + body + footer


def encode_ps(script):
    """PowerShell -EncodedCommand expects UTF-16LE base64."""
    return base64.b64encode(script.encode("utf-16-le")).decode("ascii")


def main():
    ap = argparse.ArgumentParser(
        description="Render an Office file (pptx/docx/xlsx) to PNG/PDF via Office COM on a Windows host over SSH."
    )
    ap.add_argument("input", help="path to the .pptx/.docx/.xlsx (etc.) file on this machine")
    ap.add_argument("--format", choices=["png", "pdf", "both", "auto"], default="auto",
                    help="output format. auto = png for presentations, pdf for word/excel (default)")
    ap.add_argument("--out", help="local output directory (default: /tmp/office-render/<basename>)")
    ap.add_argument("--host", default="lenovo", help="ssh host alias of the Windows machine (default: lenovo)")
    ap.add_argument("--width", type=int, default=1600, help="target PNG width in px (default: 1600)")
    ap.add_argument("--keep-remote", action="store_true", help="do not delete the remote work dir (debug)")
    args = ap.parse_args()

    src = os.path.abspath(os.path.expanduser(args.input))
    if not os.path.isfile(src):
        die(f"input file not found: {src}")
    ext = os.path.splitext(src)[1].lower()
    if ext not in APP_BY_EXT:
        die(f"unsupported extension '{ext}'. supported: {', '.join(sorted(APP_BY_EXT))}")
    app, native_png = APP_BY_EXT[ext]
    base = os.path.splitext(os.path.basename(src))[0]

    # decide formats
    fmt = args.format
    if fmt == "auto":
        fmt = "png" if app == "powerpoint" else "pdf"
    want_png = fmt in ("png", "both")
    want_pdf = fmt in ("pdf", "both")
    # for word/excel we always need a PDF (PNG is derived from it locally)
    need_remote_pdf = want_pdf or (want_png and not native_png)

    if want_png and not native_png and not shutil.which("pdftoppm"):
        die("pdftoppm (poppler-utils) not found; needed to make PNG from Word/Excel. "
            "Install poppler-utils, or use --format pdf.")

    # local output dir. For the default /tmp path we own it and clear it fully.
    # For a user-supplied --out we must NOT nuke their directory: only clear our
    # own prior render artifacts so re-runs stay idempotent.
    if args.out:
        out_dir = os.path.abspath(os.path.expanduser(args.out))
        os.makedirs(out_dir, exist_ok=True)
        for f in os.listdir(out_dir):
            if OUR_OUTPUT_RE.match(f) or f == f"{base}.pdf":
                try:
                    os.remove(os.path.join(out_dir, f))
                except OSError:
                    pass
    else:
        out_dir = os.path.join("/tmp/office-render", base)
        if os.path.isdir(out_dir):
            shutil.rmtree(out_dir)
        os.makedirs(out_dir, exist_ok=True)

    host = args.host
    if not HOST_RE.match(host):
        die(f"invalid --host value {host!r} (allowed: letters, digits, . _ -)")

    # discover remote user profile to build a work dir (assumes cmd default shell)
    r = ssh_capture(host, "echo %USERPROFILE%", timeout=30)
    if r.returncode != 0 or not r.stdout.strip():
        die(f"cannot reach host '{host}' via ssh: {r.stderr.strip() or r.stdout.strip()}")
    userprofile = r.stdout.strip().splitlines()[0].strip()
    if "%USERPROFILE%" in userprofile or ":" not in userprofile:
        die("remote %USERPROFILE% did not expand; this tool assumes a cmd default "
            f"shell on the Windows host (got: {userprofile!r}).")
    job = f"{int(time.time())}-{os.getpid()}"
    base_win = userprofile + r"\office-render\jobs" + "\\" + job     # backslash: cmd + PowerShell
    base_scp = base_win.replace("\\", "/")                           # forward slash: scp
    src_win = base_win + r"\input" + ext
    pdf_win = base_win + r"\out.pdf"
    png_win = base_win + r"\png"

    log(f"host={host}  app={app}  format={fmt}  out={out_dir}")

    def cleanup_remote():
        if args.keep_remote:
            return
        try:
            ssh_capture(host, f'rmdir /s /q "{base_win}"', timeout=30)
        except Exception:
            pass  # best-effort; never mask the original error

    # Everything from here creates/uses the remote work dir, so guard it: the
    # finally block removes the remote dir on every exit path (including die()'s
    # SystemExit and any subprocess timeout).
    try:
        # 1. remote work dir + png subdir
        r = ssh_capture(host, f'mkdir "{png_win}"', timeout=30)  # cmd mkdir makes parents
        if r.returncode != 0:
            die(f"failed to create remote work dir: {r.stderr.strip()}")

        # 2. upload source
        log("uploading source ...")
        r = scp(src, f"{host}:{base_scp}/input{ext}")
        if r.returncode != 0:
            die(f"scp upload failed: {r.stderr.strip()}")

        # 3. render via COM
        ps = build_powershell(app, src_win, need_remote_pdf, pdf_win, want_png and native_png, png_win, args.width)
        b64 = encode_ps(ps)
        log("rendering with Office COM (this can take a while on first launch) ...")
        r = ssh_capture(host, f"powershell -NoProfile -EncodedCommand {b64}", timeout=600)
        stdout = r.stdout or ""
        if r.returncode != 0 or "RENDER_OK" not in stdout:
            # surface the PowerShell error (strip CLIXML noise)
            err = "\n".join(l for l in (stdout + "\n" + (r.stderr or "")).splitlines()
                            if l.strip() and not l.lstrip().startswith(("#< CLIXML", "<Objs", "<Obj")))
            die(f"COM render failed:\n{err}")

        # empty presentation -> nothing to fetch; report clearly instead of a cryptic scp error
        if want_png and native_png:
            for line in stdout.splitlines():
                if line.strip().startswith("SLIDES=") and line.strip().split("=", 1)[1].strip() == "0":
                    die("presentation has 0 slides; nothing to render.")

        # 4. download results
        if want_png and native_png:
            r = scp(f"{host}:{base_scp}/png/*.png", out_dir + "/")
            if r.returncode != 0:
                die(f"scp download (png) failed: {r.stderr.strip()}")
        if need_remote_pdf:
            local_pdf = os.path.join(out_dir, f"{base}.pdf")
            r = scp(f"{host}:{base_scp}/out.pdf", local_pdf)
            if r.returncode != 0:
                die(f"scp download (pdf) failed: {r.stderr.strip()}")
            # 4b. rasterise PDF -> PNG locally for word/excel
            if want_png and not native_png:
                rp = run(["pdftoppm", "-png", "-scale-to-x", str(args.width), "-scale-to-y", "-1",
                          local_pdf, os.path.join(out_dir, "page")])
                if rp.returncode != 0:
                    die(f"pdftoppm failed: {rp.stderr.strip()}")
                if not want_pdf:
                    os.remove(local_pdf)
    except subprocess.TimeoutExpired as e:
        die(f"remote command timed out after {e.timeout}s; the Windows host may be "
            f"slow, hung, or a headless Office instance stalled.")
    finally:
        cleanup_remote()

    # 5. report
    pngs = sorted(f for f in os.listdir(out_dir) if f.lower().endswith(".png"))
    pdfs = sorted(f for f in os.listdir(out_dir) if f.lower().endswith(".pdf"))
    print()
    print(f"Rendered '{os.path.basename(src)}' -> {out_dir}")
    if pngs:
        print(f"  PNG pages ({len(pngs)}):")
        for f in pngs:
            print(f"    {os.path.join(out_dir, f)}")
    for f in pdfs:
        print(f"  PDF: {os.path.join(out_dir, f)}")
    if not pngs and not pdfs:
        die("no output produced (unexpected)")


if __name__ == "__main__":
    main()
