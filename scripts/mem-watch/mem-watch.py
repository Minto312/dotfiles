#!/usr/bin/env python3
"""pve 増設用の DDR4 RDIMM をヤフオク / Yahoo!フリマで監視して Discord へ流す。

狙いは「良さそうな出品が出た瞬間に気づくこと」。実際に見ていた出品が数時間で
売れてしまったので、人間が定期的に検索する運用では追いつかない。

判定方針:
  - 対象は Express5800/R120g-2M (E5-2640 v4 x2) に挿さる **DDR4 Registered ECC (RDIMM)** だけ。
  - 🔴 中古市場には「サーバー・ワークステーション用」「ECC」を名乗る **ECC UDIMM** が
    大量に混ざっている。実際に HMA41GU7AFR8N-TF / PC4-2133P-EE0-11 を最安候補として
    掴みかけた。**タイトルの日本語ではなく型番と JEDEC 表記で弾く。**
  - 型番まで確認できたものを「確定」、RDIMM/Registered としか書いていないものを
    「要確認」として、通知の中で区別する (落とさない。判断は人間がする)。

使い方:
  mem-watch.py                # 新着だけ通知
  mem-watch.py --dry-run      # Discord へ送らず標準出力に出す
  mem-watch.py --all          # 既知のものも含めて出す (棚卸し用)
  mem-watch.py --max-yen-per-gb 350
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36")

STATE_DIR = Path(os.environ.get("MEM_WATCH_STATE",
                                Path.home() / ".local/state/mem-watch"))

# 🔴 検索語は「広く 1〜2 本」。細かい語を並べるとリクエストが増えて 429 を食らう。
# どちらも価格昇順で 100 件返るので、狭い語を何本も投げるより取りこぼしが少ない。
QUERIES_FRIMA = ["RDIMM", "ECC Registered メモリ"]
QUERIES_AUCTION = ["RDIMM", "PC4 Registered"]

# ---- 規格の判定 -------------------------------------------------------------
# 🔴 ここが本体。JEDEC 表記 PC4-<speed><grade>-<X>.. の <X> が種別を表す。
#    R=Registered / E=ECC Unbuffered / U=Unbuffered / L=LRDIMM / S=SODIMM
JEDEC_RDIMM = re.compile(r"PC4-\d{4}[A-Z]-R", re.I)
JEDEC_BAD = re.compile(r"PC4-\d{4}[A-Z]-[EUSL]", re.I)

# メーカー型番。RDIMM を積極的に確定させるパターン。
PART_RDIMM = re.compile(
    r"HMA\w*?R\d\w+"           # SK hynix  HMA41G[R]7AFR4N-UH
    r"|M393A\w+"               # Samsung   M393A1G40EB1-CRC0Q
    r"|MTA\d+ASF\w*PD?Z\w*"    # Micron    MTA18ASF2G72PZ / PDZ
    r"|KVR\d+R\w+"             # Kingston  KVR21R15S4/8
    r"|CT\d+G4RFD\w*"          # Crucial   CT8G4RFD8266
    r"|ADS\d+D-R\w+",          # アドテック ADS2400D-R16GSW
    re.I)

# 明確に使えないもの。型番の 1 文字違いを見落とさないよう個別に列挙する。
PART_BAD = re.compile(
    r"HMA\w*?U\d\w+"           # SK hynix UDIMM  HMA41G[U]7AFR8N-TF ← 実際に踏みかけた
    r"|M39[128]A\w+"           # Samsung ECC UDIMM / UDIMM
    r"|M378A\w+|M471A\w+"      # Samsung UDIMM / SODIMM
    r"|MTA\d+ATF\w+"           # Micron UDIMM
    r"|MTA\d+ASF\w*AZ\w*",     # Micron ECC UDIMM
    re.I)

WORD_DDR4 = re.compile(r"DDR4|PC4-|PC4\d", re.I)   # これが無いと DDR2/DDR3 が通る
WORD_BAD = re.compile(
    r"DDR[123]\b|PC[23]-|PC3L|PC2-|SO-?DIMM|ノート用|ノートpc用"
    r"|UDIMM|unbuffered|un-?buffered|NOT\s*REG|non-?ecc"
    # LRDIMM と 3DS/TSV RDIMM は通常の RDIMM と混在できない (N8102-667 系は独立)。
    # 既存の 4GB と組み合わせられないので、2 枚だけ買っても CPU2 が空になる。
    r"|LRDIMM|4Rx4|3DS|TSV|2S2Rx4",
    re.I)
WORD_RDIMM = re.compile(r"RDIMM|Registered|ECC\s*Reg", re.I)

WORD_RISKY = re.compile(r"ジャンク|動作未確認|部品取り|保証なし|難あり", re.I)
WORD_TESTED = re.compile(r"動作確認済|動作品|memtest|検品済|テスト済|起動確認", re.I)

MIN_GB = 32          # 4 枚 (2 枚 x 2CPU) 相当より下は買っても構成が組めない
DEFAULT_MAX_YEN_PER_GB = 400
FETCH_INTERVAL = 6.0   # 秒。1 実行で 4 リクエストしか投げない


def fetch(url: str, tries: int = 4) -> str:
    """⚠ 連続で叩くと 429 が返る。フェッチ間隔は呼び出し側で空け、ここでは粘る。"""
    last = None
    for i in range(tries):
        try:
            req = urllib.request.Request(url, headers={
                "User-Agent": UA,
                "Accept-Language": "ja,en;q=0.8",
            })
            with urllib.request.urlopen(req, timeout=25) as r:
                return r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            last = e
            if e.code == 429:
                # ⚠ 実測: 一度ブロックされると即 429 が返る。粘らず次の回に賭ける
                time.sleep(5)
                if i >= 1:
                    break
            else:
                time.sleep(2 * (i + 1))
        except Exception as e:  # noqa: BLE001
            last = e
            time.sleep(2 * (i + 1))
    raise RuntimeError(f"fetch failed: {url}: {last}")


def total_gb(title: str) -> int | None:
    """タイトルから合計容量を読む。'8GB x 4枚' / '計32GB' / '32GB' の順で見る。"""
    t = title.replace("＊", "*").replace("×", "x").replace("Ｘ", "x")
    m = re.search(r"(\d{1,2})\s*GB\s*[x*＋]\s*(\d{1,2})\s*枚?", t, re.I)
    if m:
        return int(m.group(1)) * int(m.group(2))
    m = re.search(r"(?:計|合計|全)\s*(\d{2,3})\s*GB", t, re.I)
    if m:
        return int(m.group(1))
    m = re.search(r"(\d{1,2})\s*GB\s*(\d{1,2})\s*枚", t, re.I)
    if m:
        return int(m.group(1)) * int(m.group(2))
    m = re.search(r"(\d{1,3})\s*GB", t, re.I)
    if m:
        return int(m.group(1))
    return None


def classify(title: str) -> tuple[str, str] | None:
    """(確度, 理由) を返す。使えないと判定したら None。"""
    if not WORD_DDR4.search(title):
        return None
    if WORD_BAD.search(title) or PART_BAD.search(title) or JEDEC_BAD.search(title):
        return None
    if JEDEC_RDIMM.search(title):
        return ("確定", "JEDEC 表記が -R")
    if PART_RDIMM.search(title):
        return ("確定", "RDIMM の型番")
    if WORD_RDIMM.search(title):
        return ("要確認", "RDIMM 表記のみ・型番未確認")
    return None


def scan_frima(query: str) -> list[dict]:
    # 🔴 open=1 が無いと検索結果の 99% が SOLD で返る (実測: 100 件中 OPEN は 1 件)。
    # itemStatus / status といった一見それらしいパラメータは効かない。
    url = ("https://paypayfleamarket.yahoo.co.jp/search/"
           + urllib.parse.quote(query) + "?sort=price&order=asc&open=1")
    html = fetch(url)
    m = re.search(r'<script id="__NEXT_DATA__"[^>]*>(.*?)</script>', html, re.S)
    if not m:
        return []
    try:
        items = (json.loads(m.group(1))["props"]["initialState"]
                 ["searchState"]["search"]["result"]["items"])
    except (KeyError, TypeError, json.JSONDecodeError):
        return []
    out = []
    for it in items:
        if it.get("itemStatus") != "OPEN":
            continue
        out.append({
            "src": "フリマ",
            "id": it["id"],
            "title": it.get("title", ""),
            "price": int(it.get("price") or 0),
            "url": f"https://paypayfleamarket.yahoo.co.jp/item/{it['id']}",
            "note": "即決",
        })
    return out


def scan_auction(query: str) -> list[dict]:
    url = ("https://auctions.yahoo.co.jp/search/search?p="
           + urllib.parse.quote(query) + "&n=100&s1=bidorbuy&o1=a&mode=2")
    html = fetch(url)
    # タイトルの出現位置で区切り、その区間から価格と ID を拾う
    marks = [m.start() for m in re.finditer(r"Product__titleLink", html)]
    out = []
    for i, pos in enumerate(marks):
        seg = html[pos:marks[i + 1] if i + 1 < len(marks) else pos + 4000]
        tm = re.search(r">([^<]{4,200})</a>", seg)
        im = re.search(r"/jp/auction/([a-z]?\d{9,10})", seg)
        if not tm or not im:
            continue
        now = re.search(r"Product__priceValue[^>]*>\s*([\d,]+)", seg)
        buy = re.findall(r"Product__priceValue[^>]*>\s*([\d,]+)", seg)
        if not now:
            continue
        price = int(now.group(1).replace(",", ""))
        note = "入札中"
        if len(buy) > 1:
            note = f"即決 {int(buy[1].replace(',', '')):,}円"
        out.append({
            "src": "ヤフオク",
            "id": im.group(1),
            "title": re.sub(r"\s+", " ", tm.group(1)).strip(),
            "price": price,
            "url": f"https://page.auctions.yahoo.co.jp/jp/auction/{im.group(1)}",
            "note": note,
        })
    return out


def collect(max_per_gb: int) -> list[dict]:
    seen_ids: set[str] = set()
    hits: list[dict] = []
    jobs = ([(scan_frima, q) for q in QUERIES_FRIMA]
            + [(scan_auction, q) for q in QUERIES_AUCTION])
    for scan, q in jobs:
            time.sleep(FETCH_INTERVAL)  # ⚠ 429 対策。詰めると必ず弾かれる
            try:
                rows = scan(q)
            except Exception as e:  # noqa: BLE001
                # 片方が 429 でも、もう片方の結果は流したいので継続する
                print(f"warn: {scan.__name__}({q}): {e}", file=sys.stderr)
                continue
            for r in rows:
                if r["id"] in seen_ids:
                    continue
                seen_ids.add(r["id"])
                verdict = classify(r["title"])
                if not verdict:
                    continue
                gb = total_gb(r["title"])
                if not gb or gb < MIN_GB or gb > 256 or r["price"] <= 0:
                    continue
                per_gb = round(r["price"] / gb)
                if per_gb > max_per_gb:
                    continue
                r.update(gb=gb, per_gb=per_gb, grade=verdict[0], why=verdict[1],
                         risky=bool(WORD_RISKY.search(r["title"])),
                         tested=bool(WORD_TESTED.search(r["title"])))
                hits.append(r)
    hits.sort(key=lambda x: x["per_gb"])
    return hits


def load_seen() -> set[str]:
    f = STATE_DIR / "seen.txt"
    return set(f.read_text().split()) if f.exists() else set()


def save_seen(ids: set[str]) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    (STATE_DIR / "seen.txt").write_text("\n".join(sorted(ids)) + "\n")


def webhook_url() -> str | None:
    if os.environ.get("DISCORD_WEBHOOK_URL"):
        return os.environ["DISCORD_WEBHOOK_URL"]
    cfg = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    # notify-discord.sh と同じ探索順にする (先に見つかった方が実質の宛先)
    for p in (cfg / "mem-watch/env", cfg / "resource-audit/env",
              cfg / "discord-notify/env"):
        if not p.exists():
            continue
        for line in p.read_text().splitlines():
            line = line.strip()
            if line.startswith("DISCORD_WEBHOOK_URL="):
                return line.split("=", 1)[1].strip().strip('"').strip("'")
    return None


def render(hits: list[dict]) -> str:
    lines = [f"**pve 増設用 DDR4 RDIMM の新着 {len(hits)} 件**"]
    for h in hits:
        flag = "✅" if h["grade"] == "確定" else "❓"
        tags = []
        if h["tested"]:
            tags.append("動作確認済")
        if h["risky"]:
            tags.append("⚠️ジャンク/未確認")
        tag = f" [{' / '.join(tags)}]" if tags else ""
        lines.append(
            f"\n{flag} **{h['per_gb']:,}円/GB** — {h['price']:,}円 / {h['gb']}GB"
            f" ({h['src']}・{h['note']}){tag}\n"
            f"{h['title'][:90]}\n{h['url']}")
    lines.append("\n⚠️ 型番と JEDEC 表記 (`PC4-xxxxx-**R**`) を必ず自分の目で確認すること。"
                 "❓ は RDIMM 表記のみで型番未確認。")
    return "\n".join(lines)


def notify(text: str) -> None:
    url = webhook_url()
    if not url:
        print("warn: webhook 未設定。通知をスキップ", file=sys.stderr)
        return
    for chunk_start in range(0, len(text), 1900):
        body = json.dumps({"content": text[chunk_start:chunk_start + 1900]}).encode()
        req = urllib.request.Request(url, data=body, headers={
            "Content-Type": "application/json", "User-Agent": "mem-watch"})
        with urllib.request.urlopen(req, timeout=20) as r:
            r.read()
        time.sleep(0.5)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--all", action="store_true", help="既知の出品も出す")
    ap.add_argument("--max-yen-per-gb", type=int, default=DEFAULT_MAX_YEN_PER_GB)
    a = ap.parse_args()

    hits = collect(a.max_yen_per_gb)
    seen = load_seen()
    fresh = hits if a.all else [h for h in hits if h["id"] not in seen]

    print(f"検出 {len(hits)} 件 / 新着 {len(fresh)} 件 "
          f"(上限 {a.max_yen_per_gb}円/GB, 最小 {MIN_GB}GB)", file=sys.stderr)
    if not fresh:
        if not a.all:
            save_seen(seen | {h["id"] for h in hits})
        return 0

    text = render(fresh)
    if a.dry_run:
        print(text)
    else:
        notify(text)
        save_seen(seen | {h["id"] for h in hits})
    return 0


if __name__ == "__main__":
    sys.exit(main())
