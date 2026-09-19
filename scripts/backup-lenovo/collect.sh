#!/usr/bin/env bash
# lenovo (Windows) の構成スナップショットを採って machine リポジトリに落とす。
# 設計と復元手順は ~/workspace/machine/storage/backup-lenovo/README.md。
#
# ・lenovo はノートで常時起動していないので、届かない回は失敗ではなく status=skip。
# ・中身が変わった回だけコミットする (push はしない。リポジトリは restic L1/L3 に乗っている)。
# ・webhook は持たない。logfmt を journald に吐くだけ (判定は Grafana 側)。
set -uo pipefail

REPO="$HOME/workspace/machine"
SNAP="$REPO/storage/backup-lenovo/snapshot"
PS1_SRC="$REPO/storage/backup-lenovo/collect.ps1"
REMOTE_PS1='C:/Users/karinto/AppData/Local/Temp/collect.ps1'
HOST="${LENOVO_HOST:-lenovo}"

START=$(date +%s)
log() { printf 'ts=%s job=lenovo-config-collect %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
finish() { log "$* duration_s=$(( $(date +%s) - START ))"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# --- 0. 前提 ---
[ -f "$PS1_SRC" ] || { finish "status=error stage=precheck reason=collect_ps1_missing"; exit 1; }
if [ -e "$REPO/.git/MERGE_HEAD" ] || [ -d "$REPO/.git/rebase-merge" ] || [ -d "$REPO/.git/rebase-apply" ]; then
    finish "status=skip reason=repo_busy"; exit 0
fi

# --- 1. 届くか (ノートなので落ちているのが普通) ---
if ! timeout 30 ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" 'exit 0' >/dev/null 2>&1; then
    finish "status=skip reason=unreachable"; exit 0
fi

# --- 2. 採取スクリプトを送って走らせる ---
if ! timeout 60 scp -q -o BatchMode=yes "$PS1_SRC" "$HOST:$REMOTE_PS1" >/dev/null 2>&1; then
    finish "status=error stage=scp"; exit 1
fi
if ! timeout 900 ssh -o BatchMode=yes "$HOST" 'pwsh -NoProfile -File "$env:TEMP\collect.ps1"' >/dev/null 2>&1; then
    finish "status=error stage=collect"; exit 1
fi

# --- 3. 回収は必ず base64 (> で落とすと UTF-16LE + mojibake になる) ---
if ! timeout 300 ssh -o BatchMode=yes "$HOST" \
        '[Convert]::ToBase64String([IO.File]::ReadAllBytes("$env:TEMP\lenovo-config-snapshot.zip"))' \
        2>/dev/null | base64 -d > "$TMP/snap.zip"; then
    finish "status=error stage=fetch"; exit 1
fi
[ -s "$TMP/snap.zip" ] || { finish "status=error stage=fetch reason=empty"; exit 1; }
mkdir -p "$TMP/new"
unzip -qo "$TMP/snap.zip" -d "$TMP/new" || { finish "status=error stage=unzip"; exit 1; }
[ -f "$TMP/new/settings.txt" ] || { finish "status=error stage=unzip reason=incomplete"; exit 1; }

# --- 4. 置き換え ---
mkdir -p "$SNAP"
rsync -a --delete "$TMP/new/" "$SNAP/" || { finish "status=error stage=rsync"; exit 1; }

# --- 5. 実質的な差分だけを見る ---
# collected-at.txt と packages.json の CreationDate は毎回変わるのでノイズ。
REAL=0
CHANGED=$(git -C "$REPO" status --porcelain -- storage/backup-lenovo/snapshot | awk '{print $NF}')
for f in $CHANGED; do
    case "$(basename "$f")" in
        collected-at.txt) continue ;;
        packages.json)
            if git -C "$REPO" diff -U0 -- "$f" \
                 | grep -E '^[+-]' | grep -Ev '^(\+\+\+|---)' | grep -qv 'CreationDate'; then
                REAL=1
            fi
            continue ;;
    esac
    REAL=1
done

if [ "$REAL" -eq 0 ]; then
    git -C "$REPO" checkout -- storage/backup-lenovo/snapshot 2>/dev/null
    finish "status=ok changed=0"
    exit 0
fi

# --- 6. 変わった回だけコミット (他のパスは触らない) ---
N=$(printf '%s\n' $CHANGED | grep -c . )
if ! git -C "$REPO" commit -q -o storage/backup-lenovo/snapshot \
        -m "chore(lenovo): 構成スナップショットを更新する (自動採取)" 2>/dev/null; then
    finish "status=error stage=commit changed=1 files=$N"; exit 1
fi
finish "status=ok changed=1 files=$N commit=$(git -C "$REPO" rev-parse --short HEAD)"
