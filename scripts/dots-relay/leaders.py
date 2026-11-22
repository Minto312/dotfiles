"""tmux のリーダー (@agent_name=leader のペインの Claude) を見つけ、依頼を貼り付け、返答を読む。

ペインの扱いは tmux スキル・orchestrate スキルの決まりに合わせる。
- 送るのは、状態が idle か done で、高島さんが見ておらず、入力欄が空のときだけ
- 送る前に @agent_state を sent にし、フックが書き換えるのを待つ
"""

from __future__ import annotations

import asyncio
import glob
import json
import os
import re
from collections import Counter
from pathlib import Path

ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")
# 薄い文字 (ESC[2m) は Claude Code が出す入力の候補で、高島さんの入力ではない
DIM = re.compile(r"\x1b\[2m.*?(?=\x1b\[(?:0|22)m|$)", re.S)

FIELDS = [
    "pane_id", "window_index", "window_name", "@agent_name", "@agent_state",
    "pane_active", "window_active", "session_attached", "pane_current_command",
    "pane_pid", "pane_title", "pane_index",
]
FMT = "\t".join("#{%s}" % f for f in FIELDS)

ALLOWED_KEYS = {str(i) for i in range(1, 10)} | {"Enter", "Escape", "Up", "Down", "Tab", "y", "n"}


async def tmux(*args: str, check: bool = True) -> str:
    proc = await asyncio.create_subprocess_exec(
        "tmux", *args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
    )
    out, err = await proc.communicate()
    if check and proc.returncode:
        raise RuntimeError(err.decode(errors="replace").strip() or f"tmux {args[0]} failed")
    return out.decode(errors="replace")


async def list_leaders() -> list[dict]:
    """leader という名前のペインだけを返す。名前を付けていないペインには送らない。"""
    out = await tmux("list-panes", "-a", "-F", FMT)
    rows = []
    for line in out.splitlines():
        f = line.split("\t")
        if len(f) != len(FIELDS) or f[3] != "leader":
            continue
        rows.append({
            "pane": f[0],
            "window_index": int(f[1] or 0),
            "window": f[2],
            "state": f[4] or "",
            "pane_active": f[5] == "1",
            "window_active": f[6] == "1",
            "attached": int(f[7] or 0),
            "cmd": f[8],
            "pane_pid": int(f[9] or 0),
            "title": f[10].lstrip("✳ ").strip(),
            "pane_index": int(f[11] or 0),
        })
    counts = Counter(r["window"].split("/")[0] for r in rows)
    for r in rows:
        ws = r["window"].split("/")[0]
        r["workspace"] = ws
        r["id"] = ws if counts[ws] == 1 else f"{ws}-w{r['window_index']}"
        r["label"] = f"{r['id']} (w{r['window_index']} p{r['pane_index']})"
    return rows


async def find_leader(leader_id: str) -> dict | None:
    for r in await list_leaders():
        if r["id"] == leader_id:
            return r
    return None


async def pane_state(pane: str) -> str | None:
    try:
        return (await tmux("display", "-p", "-t", pane, "#{@agent_state}")).strip()
    except RuntimeError:
        return None


async def input_text(pane: str) -> str | None:
    """入力欄の文字を返す。空なら ""、画面の形が読めなければ None。"""
    raw = await tmux("capture-pane", "-p", "-e", "-t", pane)
    lines = raw.split("\n")
    plain = [ANSI.sub("", line).strip() for line in lines]
    # 入力欄の上下の横線。上の線には会話の名前が入ることがある (例: "──── rust-sshd-tray-launcher ──")
    rules = [i for i, line in enumerate(plain) if line.startswith("─") and line.count("─") >= 20]
    if len(rules) < 2:
        return None
    a, b = rules[-2], rules[-1]
    body = "\n".join(DIM.sub("", line) for line in lines[a + 1 : b])
    body = ANSI.sub("", body).replace("❯", "").replace(" ", " ")
    return body.strip()


async def busy_reason(r: dict) -> str | None:
    """送れないときは理由を返す。送れるなら None。"""
    if r["cmd"] not in ("claude", "node"):
        return f"Claude が動いていない (前面は {r['cmd']})"
    if r["state"] not in ("idle", "done"):
        return f"作業中か確認待ち (状態: {r['state'] or '不明'})"
    if r["pane_active"] and r["window_active"] and r["attached"] >= 1:
        return "高島さんがこのペインを見ている"
    text = await input_text(r["pane"])
    if text is None:
        return "入力欄を読めない"
    if text:
        return "入力欄に高島さんの入力がある"
    return None


async def deliver(pane: str, text: str, buffer_name: str, tmpdir: Path) -> None:
    path = tmpdir / f"{buffer_name}.txt"
    path.write_text(text, encoding="utf-8")
    try:
        await tmux("set", "-p", "-t", pane, "@agent_state", "sent")
        await tmux("load-buffer", "-b", buffer_name, str(path))
        await tmux("paste-buffer", "-p", "-d", "-b", buffer_name, "-t", pane)
        await asyncio.sleep(1)
        await tmux("send-keys", "-t", pane, "Enter")
    finally:
        path.unlink(missing_ok=True)


async def press_keys(pane: str, keys: list[str]) -> None:
    bad = [k for k in keys if k not in ALLOWED_KEYS]
    if bad:
        raise ValueError(f"使えないキー: {bad} (使えるのは {sorted(ALLOWED_KEYS)})")
    for k in keys:
        await tmux("send-keys", "-t", pane, k)
        await asyncio.sleep(0.3)


async def screen_tail(pane: str, lines: int = 40) -> str:
    raw = await tmux("capture-pane", "-p", "-J", "-t", pane, "-S", f"-{max(lines, 1)}")
    return "\n".join(line.rstrip() for line in raw.rstrip("\n").split("\n")[-lines:])


def claude_pid(pane_pid: int) -> int | None:
    for stat in glob.glob("/proc/[0-9]*/stat"):
        try:
            data = Path(stat).read_text()
        except OSError:
            continue
        comm = data[data.find("(") + 1 : data.rfind(")")]
        ppid = int(data[data.rfind(")") + 2 :].split()[1])
        if ppid == pane_pid and comm in ("claude", "node"):
            return int(Path(stat).parent.name)
    return None


def session_jsonl(pane_pid: int) -> str | None:
    """ペインの Claude が書いている会話の記録 (JSONL) のパス。

    ~/.claude/sessions/<pid>.json は Claude Code の内部のファイル (tmux-agents restart と同じ前提)。
    """
    pid = claude_pid(pane_pid)
    if pid is None:
        return None
    try:
        sid = json.loads(Path(f"~/.claude/sessions/{pid}.json").expanduser().read_text())["sessionId"]
    except (OSError, ValueError, KeyError):
        return None
    cands = glob.glob(os.path.expanduser(f"~/.claude/projects/*/{sid}.jsonl"))
    return max(cands, key=os.path.getmtime) if cands else None


def final_reply(path: str, offset: int) -> str:
    """offset より後に書かれた、最後の道具の使用より後の返答の文を返す。

    Stop フックが足す通知のやり取り (PushNotification と、フックの文で始まる発話) は、返答に含めない。
    """
    with open(path, "rb") as f:
        f.seek(offset)
        data = f.read()
    texts: list[str] = []
    frozen = False
    for line in data.decode("utf-8", errors="replace").splitlines():
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if e.get("type") == "user" and texts:
            content = e.get("message", {}).get("content")
            body = content if isinstance(content, str) else json.dumps(content, ensure_ascii=False)
            if "Stop hook" in body or "[notify hook]" in body:
                frozen = True
        if frozen or e.get("type") != "assistant":
            continue
        for c in e.get("message", {}).get("content") or []:
            if c.get("type") == "tool_use":
                if c.get("name") == "PushNotification":
                    frozen = True
                    break
                texts = []
            elif c.get("type") == "text" and c.get("text", "").strip():
                texts.append(c["text"].strip())
    return "\n\n".join(texts).strip()
