#!/usr/bin/env python3
"""Markdown viewer: serves .md files in cwd as rendered HTML."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs, quote, unquote
from pathlib import Path
import sys

# スキルディレクトリに常設し、起動時のカレントディレクトリを公開ルートとする
ROOT = Path.cwd().resolve()
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 9876

INDEX_TMPL = """<!doctype html>
<html lang="ja"><head><meta charset="utf-8">
<title>MD Viewer</title>
<style>
body{{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI","Hiragino Sans","Noto Sans JP",sans-serif;max-width:760px;margin:2rem auto;padding:0 1rem;color:#222;line-height:1.7}}
h1{{border-bottom:2px solid #333;padding-bottom:.3em}}
ul{{list-style:none;padding:0}}
li{{padding:.4em 0;border-bottom:1px solid #eee}}
a{{color:#0366d6;text-decoration:none}}
a:hover{{text-decoration:underline}}
.size{{color:#888;font-size:.85em;margin-left:.6em}}
</style></head><body>
<h1>📚 Markdown Files</h1>
<ul>{items}</ul>
</body></html>"""

VIEW_TMPL = """<!doctype html>
<html lang="ja"><head><meta charset="utf-8">
<title>{title}</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/github-markdown-css@5.5.1/github-markdown-light.min.css">
<script src="https://cdn.jsdelivr.net/npm/marked@12.0.2/marked.min.js"></script>
<style>
body{{margin:0;background:#fafbfc}}
.bar{{position:sticky;top:0;background:#fff;border-bottom:1px solid #e1e4e8;padding:.6em 1em;font-family:-apple-system,BlinkMacSystemFont,sans-serif;display:flex;gap:1em;align-items:center;z-index:10}}
.bar a{{color:#0366d6;text-decoration:none;font-size:.9em}}
.bar .title{{font-weight:600;color:#333}}
.markdown-body{{box-sizing:border-box;max-width:860px;margin:2em auto;padding:2em 3em;background:#fff;border:1px solid #e1e4e8;border-radius:6px}}
@media(max-width:767px){{.markdown-body{{padding:1.2em;margin:1em}}}}
</style></head><body>
<div class="bar"><a href="/">← Index</a><span class="title">{title}</span></div>
<article id="content" class="markdown-body">読み込み中…</article>
<script>
fetch({raw_path}).then(r=>r.text()).then(t=>{{
  document.getElementById('content').innerHTML = marked.parse(t, {{breaks:true, gfm:true}});
}}).catch(e=>{{document.getElementById('content').textContent='読み込み失敗: '+e}});
</script>
</body></html>"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("[%s] %s\n" % (self.address_string(), fmt % args))

    def do_GET(self):
        u = urlparse(self.path)
        path = unquote(u.path)
        qs = parse_qs(u.query)

        if path == "/" or path == "/index.html":
            return self._serve_index()
        if path == "/view":
            f = qs.get("file", [""])[0]
            return self._serve_view(f)
        if path == "/raw":
            f = qs.get("file", [""])[0]
            return self._serve_raw(f)
        self._404()

    def _resolve(self, name: str) -> Path | None:
        if not name:
            return None
        p = (ROOT / name).resolve()
        if not p.is_relative_to(ROOT) or not p.is_file():
            return None
        return p

    def _serve_index(self):
        files = sorted(ROOT.glob("*.md"))
        items = "\n".join(
            f'<li><a href="/view?file={quote(f.name)}">{f.name}</a>'
            f'<span class="size">{f.stat().st_size:,} bytes</span></li>'
            for f in files
        )
        body = INDEX_TMPL.format(items=items or "<li>(no .md files)</li>")
        self._send(200, "text/html; charset=utf-8", body.encode("utf-8"))

    def _serve_view(self, name: str):
        p = self._resolve(name)
        if not p or p.suffix.lower() != ".md":
            return self._404()
        raw_path = f'"/raw?file={quote(name)}"'
        body = VIEW_TMPL.format(title=name, raw_path=raw_path)
        self._send(200, "text/html; charset=utf-8", body.encode("utf-8"))

    def _serve_raw(self, name: str):
        p = self._resolve(name)
        if not p:
            return self._404()
        self._send(200, "text/plain; charset=utf-8", p.read_bytes())

    def _send(self, code: int, ctype: str, body: bytes):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _404(self):
        self._send(404, "text/plain; charset=utf-8", b"404 Not Found")


if __name__ == "__main__":
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"MD viewer: http://0.0.0.0:{PORT}/  (root={ROOT})")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        srv.shutdown()
