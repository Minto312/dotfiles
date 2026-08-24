#!/usr/bin/env python3
"""codex の残 quota を app-server の JSON-RPC 経由で 1 回読み、JSON を stdout に出す。

なぜ app-server なのか:
  codex には `/usage` に相当する非対話コマンドが無い。session の rollout JSONL には
  `rate_limits` が入っているが、あれは**ターンを回したときの副産物**なので最後に
  codex を使った時点の値しか残らない (実測で 5 日前の値を掴んだ)。
  `codex app-server` の `account/rateLimits/read` は**ターンを起こさずに現在値**を返す。

プロトコル上の注意 (どれも実測で踏んだ):
  - stdio に 1 行 1 JSON-RPC。`initialize` を先に通さないと後続が弾かれる。
  - メソッド名は `account/rateLimits` ではなく **`account/rateLimits/read`**
    (前者は unknown variant。正しい一覧は不正なメソッドを投げると列挙される)。
  - 🔴 **リクエストを書いた直後に stdin を閉じてはいけない**。閉じると app-server が
    応答を返す前に終了してしまう (`subprocess.run(input=...)` だと必ずこうなる)。
    stdin は開いたままにして、id=2 の行を読めた時点でこちらから落とす。
  - 応答の前に `remoteControl/status/changed` などの通知行が挟まる。
    type ではなく **id で選ぶ**。
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import threading

TIMEOUT = 30


def read_rate_limits(codex: str) -> tuple[dict | None, str]:
    proc = subprocess.Popen(
        [codex, "app-server"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        bufsize=1,
    )

    # 読みは行単位のブロッキングなので、締め切りは外から殺して守る。
    killer = threading.Timer(TIMEOUT, proc.kill)
    killer.start()
    try:
        reqs = [
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "clientInfo": {
                        "name": "llm-quota",
                        "title": "llm-quota",
                        "version": "1.0.0",
                    }
                },
            },
            {
                "jsonrpc": "2.0",
                "id": 2,
                "method": "account/rateLimits/read",
                "params": {},
            },
        ]
        assert proc.stdin is not None and proc.stdout is not None
        for req in reqs:
            proc.stdin.write(json.dumps(req) + "\n")
        proc.stdin.flush()
        # stdin は閉じない (閉じると応答前に終わる)。

        for line in proc.stdout:
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue
            if msg.get("id") != 2:
                continue
            if "error" in msg:
                return None, str(msg["error"].get("message", "rpc error"))[:200]
            result = msg.get("result") or {}
            rl = result.get("rateLimits")
            if rl is None:
                return None, "response had no rateLimits"
            # 「無料のレートリミットリセット券」は残枚数が運用判断に効くので一緒に返す。
            # ⚠ credits.balance (課金クレジット) とは別物。rateLimits の外側にある。
            rl = dict(rl)
            rl["_resetCredits"] = result.get("rateLimitResetCredits") or {}
            return rl, ""
        return None, f"stream ended without an id=2 response (timeout {TIMEOUT}s?)"
    finally:
        killer.cancel()
        proc.kill()
        proc.wait(timeout=5)


def main() -> int:
    codex = shutil.which("codex")
    if codex is None:
        print(json.dumps({"ok": False, "error": "codex not found on PATH"}))
        return 0
    try:
        rl, err = read_rate_limits(codex)
    except Exception as exc:  # noqa: BLE001 - 監視なので絶対に落とさない
        print(json.dumps({"ok": False, "error": f"{type(exc).__name__}: {exc}"[:200]}))
        return 0
    if rl is None:
        print(json.dumps({"ok": False, "error": err}))
        return 0
    print(json.dumps({"ok": True, "rate_limits": rl}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
