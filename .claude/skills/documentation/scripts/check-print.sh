#!/usr/bin/env bash
# artifact の HTML を印刷したときのページ数を出し、PDF と見た目が同じかを確かめる。
#
# 使い方: check-print.sh <artifact.html> [<比べる PDF>]
#   - artifact の HTML（<!doctype> を持たない、公開用のファイル）を、公開時の外枠に近い形で包んで
#     headless Chrome で印刷する。ページ数を出し、各ページの PNG を作業ディレクトリに残す。
#   - PDF を渡すと、両方を同じ解像度で画像にし、ページごとに「差が大きい画素の数」を出す。
#     数画素なら同じと見てよい。ページ数が違えば、その時点で知らせる。
# 必要なもの: google-chrome, pdfinfo, pdftoppm, python3 と Pillow
set -euo pipefail

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
fi
src=$(readlink -f "$1")
ref=${2:+$(readlink -f "$2")}
work=$(mktemp -d "${TMPDIR:-/tmp}/check-print.XXXXXX")

{
  printf '<!doctype html><html><head><meta charset="utf-8">'
  printf '<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">'
  printf '<style>:root{color-scheme:light;padding-top:env(safe-area-inset-top,0px);padding-bottom:env(safe-area-inset-bottom,0px)}'
  printf 'body{margin:0;font:14px system-ui,sans-serif}img{max-width:100%%}[hidden]{display:none!important}</style></head><body>\n'
  cat "$src"
  printf '\n</body></html>\n'
} > "$work/wrapped.html"

google-chrome --headless --disable-gpu --no-sandbox --no-pdf-header-footer \
  --virtual-time-budget=8000 --print-to-pdf="$work/artifact.pdf" "file://$work/wrapped.html" >/dev/null 2>&1
pages=$(pdfinfo "$work/artifact.pdf" | awk '/^Pages:/{print $2}')
echo "artifact を印刷したページ数: $pages"
pdftoppm -png -r 80 "$work/artifact.pdf" "$work/artifact"
echo "各ページの画像: $work/artifact-*.png"

if [ -n "$ref" ]; then
  rpages=$(pdfinfo "$ref" | awk '/^Pages:/{print $2}')
  echo "比べる PDF のページ数: $rpages"
  if [ "$pages" != "$rpages" ]; then
    echo "ページ数が違います" >&2
    exit 1
  fi
  pdftoppm -png -r 50 "$work/artifact.pdf" "$work/a"
  pdftoppm -png -r 50 "$ref" "$work/b"
  python3 -I - "$work" <<'PY'
import sys, glob, os
from PIL import Image, ImageChops
work = sys.argv[1]
for a_path in sorted(glob.glob(os.path.join(work, "a-*.png"))):
    n = a_path.rsplit("-", 1)[1]
    a = Image.open(a_path).convert("L")
    b = Image.open(os.path.join(work, "b-" + n)).convert("L")
    if a.size != b.size:
        print(f"ページ {n[:-4]}: 大きさが違います {a.size} {b.size}")
        continue
    diff = ImageChops.difference(a, b)
    count = sum(1 for v in diff.tobytes() if v > 40)
    print(f"ページ {n[:-4]}: 差が大きい画素 {count}")
PY
fi
