#!/usr/bin/env bash
# tldv-ingest 共通ライブラリ
#
# Google Drive の受け皿フォルダに置かれた音声/動画を tl;dv に取り込む。
#
# 設計の要点:
#   - tl;dv の import API は「公開アクセス可能な URL」しか受け付けない (multipart 不可)。
#     そこで Drive の権限に anyone/reader を一時的に足し、取り込み完了後に剥がす。
#     バイト列は develop を一切通らない (tl;dv が Google から直接取得する) ので
#     100MB 超・GB 級でも転送コストがかからない。
#   - ⚠ Drive が返す webContentLink (drive.google.com/uc?...) は 100MB を超えると
#     ウイルススキャンの確認 HTML を返す。必ず
#     drive.usercontent.google.com/download?...&confirm=t を使い、
#     投入前に「HTML ではなくメディアが返ること」を実際に確認する。
#   - 通知は持たない。ログは stdout に logfmt で吐き、journald 経由で
#     Alloy → VictoriaLogs に入る。閾値判定とアラートは Grafana Alerting 側の担当。

set -euo pipefail

TLDV_API=${TLDV_API:-https://pasta.tldv.io/v1alpha1}
STATE_DIR=${TLDV_STATE_DIR:-$HOME/.local/state/tldv-ingest}
INFLIGHT_DIR="$STATE_DIR/inflight"
ATTEMPT_DIR="$STATE_DIR/attempts"
HAPPENED_DIR="$STATE_DIR/happened"
SPLIT_DIR="$STATE_DIR/split"
LEDGER="$STATE_DIR/ledger.jsonl"
# gws は本文が無いレスポンス (204) のとき cwd に download.html を書く。
# 呼び出しは必ずこの捨てディレクトリで行い、作業ディレクトリを汚さない。
SCRATCH_DIR="$STATE_DIR/scratch"

# tl;dv がサポートする拡張子 (OpenAPI の url フィールド description より)
SUPPORTED_EXT="mp3 mp4 wav m4a mkv mov avi wma flac"

# ---------------------------------------------------------------- logging

log() { # level event [key=val ...]
	local level=$1 event=$2
	shift 2
	printf '%s level=%s event=%s' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$event"
	local kv
	for kv in "$@"; do printf ' %s' "$kv"; done
	printf '\n'
}
info() { log info "$@"; }
warn() { log warn "$@" >&2; }
err() { log error "$@" >&2; }

# ログに載せる値のクォート (空白を含むファイル名などのため。%q は日本語が
# $'\346...' に化けて読めなくなるので使わない)
q() { printf '%s="%s"' "$1" "${2//\"/\'}"; }

# ---------------------------------------------------------------- gws

# systemd --user の PATH には nvm が無い。unit 側に頼らず自力で解決する。
#
# ⚠ 値を stdout で返してはいけない。gws は `#!/usr/bin/env node` の Node スクリプトで、
#   nvm 配下にあるため **その bin ディレクトリを PATH に足さないと node が見つからず
#   起動できない**。$(...) で呼ぶと PATH の修正がサブシェルで消えるので、
#   グローバル変数 GWS を直接立てる関数にしている。
setup_gws() {
	local p='' c d
	if [ -n "${GWS_BIN:-}" ] && [ -x "$GWS_BIN" ]; then
		p=$GWS_BIN
	elif c=$(command -v gws 2>/dev/null); then
		p=$c
	else
		for c in "$HOME"/.nvm/versions/node/*/bin/gws "$HOME"/.local/bin/gws; do
			if [ -x "$c" ]; then
				p=$c
				break
			fi
		done
	fi
	if [ -z "$p" ]; then
		err gws_not_found "hint=~/.config/tldv-ingest/env に GWS_BIN を書く"
		return 1
	fi
	# gws と node は同じ bin ディレクトリに居る (nvm/npm の慣習)。
	d=$(dirname "$p")
	case ":$PATH:" in
	*":$d:"*) ;;
	*) export PATH="$d:$PATH" ;;
	esac
	GWS=$p
}

# gws は banner を stderr に出すので stdout だけを拾う。
# ⚠ gws は --output / --upload に「cwd の外」のパスを渡すと 400 で弾く
#   (--output /dev/null すら通らない)。かつ本文の無いレスポンスでは cwd に
#   download.html を書く。そこで常に捨てディレクトリに cd して呼ぶ。
gws_drive() { # subcommand...
	(cd "$SCRATCH_DIR" && "$GWS" drive "$@" 2>/dev/null)
}

drive_files_list() { # q fields [extra_json]
	local params extra=${3:-}
	[ -n "$extra" ] || extra='{}'
	params=$(jq -nc --arg q "$1" --arg f "$2" --argjson extra "$extra" \
		'{q:$q,fields:$f,pageSize:100,orderBy:"createdTime"} + $extra')
	gws_drive files list --params "$params"
}

drive_file_get() { # fileId fields
	gws_drive files get --params "$(jq -nc --arg i "$1" --arg f "$2" '{fileId:$i,fields:$f}')"
}

drive_share_public() { # fileId -> permission id
	gws_drive permissions create \
		--params "$(jq -nc --arg i "$1" '{fileId:$i,fields:"id,type,role"}')" \
		--json '{"role":"reader","type":"anyone"}' | jq -r '.id // empty'
}

# 公開の剥がしは「やったつもり」で済ませてはいけない。削除後に実際に
# anyone 権限が消えたことを確認し、消えていなければ失敗として返す。
drive_unshare() { # fileId permissionId
	gws_drive permissions delete \
		--params "$(jq -nc --arg i "$1" --arg p "$2" '{fileId:$i,permissionId:$p}')" \
		>/dev/null || true
	if drive_is_public "$1"; then
		err unshare_verify_failed "file_id=$1" "perm_id=$2" \
			"note=ファイルが公開のまま残っている。手動で共有を解除する"
		return 1
	fi
	return 0
}

drive_is_public() { # fileId -> 0 if an anyone-type permission exists
	local perms
	perms=$(gws_drive permissions list \
		--params "$(jq -nc --arg i "$1" '{fileId:$i,fields:"permissions(id,type,role)"}')")
	printf '%s' "$perms" | jq -e '[.permissions[]? | select(.type=="anyone")] | length > 0' >/dev/null
}

drive_move() { # fileId fromParent toParent
	gws_drive files update \
		--params "$(jq -nc --arg i "$1" --arg r "$2" --arg a "$3" \
			'{fileId:$i,addParents:$a,removeParents:$r,fields:"id,parents"}')" \
		--json '{}' >/dev/null
}

# 目的のフォルダに居ることを保証する。
# 投入時の done/ への移動が失敗したまま刈り取りで inflight を消すと、
# ファイルが inbox に残っているので次回に二重投入される。その穴を塞ぐ用。
drive_ensure_parent() { # fileId targetParent
	local parents
	parents=$(drive_file_get "$1" 'parents' | jq -r '.parents[]?' | tr '\n' ' ')
	case " $parents " in
	*" $2 "*) return 0 ;;
	esac
	local p
	for p in $parents; do
		drive_move "$1" "$p" "$2" && return 0
	done
	return 1
}

# 公開ダウンロード URL。⚠ webContentLink ではなくこちらを使う (100MB 超の確認ページ回避)
public_media_url() { # fileId
	printf 'https://drive.usercontent.google.com/download?id=%s&export=download&confirm=t' "$1"
}

# URL が本当にメディアを返すか (= HTML の確認ページや sign-in ページでないか) を
# 未認証で確かめる。先頭 2KB のレンジ要求だけなので転送量はほぼゼロ。
verify_public_media() { # url -> prints "http=<code> type=<ct>" ; rc 0 if媒体
	local url=$1 out
	out=$(curl -sS -L --max-time 60 --retry 2 --retry-delay 3 \
		-H 'Range: bytes=0-2047' -o /dev/null \
		-w 'http=%{http_code} type=%{content_type} len=%{size_download}' "$url" 2>/dev/null) || {
		printf 'http=000 type=curl_failed len=0'
		return 1
	}
	printf '%s' "$out"
	case "$out" in
	*"type=text/html"*) return 1 ;;
	*"http=200"* | *"http=206"*) return 0 ;;
	*) return 1 ;;
	esac
}

# ---------------------------------------------------------------- media

# 公開 URL から尺だけを引く。
# ⚠ 全部は落とさない — ffprobe は range 要求で moov atom だけを取るので、
#   45MB の m4a で実測 1.3 MiB しか流れない (「バイト列が develop を通らない」
#   という設計の性質をほぼ保てる)。
media_duration() { # url -> 秒 (整数)。引けなければ rc 1
	local d
	command -v ffprobe >/dev/null 2>&1 || return 1
	d=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$1" 2>/dev/null) || return 1
	case "$d" in
	'' | N/A | 0) return 1 ;;
	esac
	printf '%.0f' "$d"
}

# ローカルのファイルを Drive へ上げる。
# ⚠ gws は --upload に cwd の外のパスを拒むので、置いてあるディレクトリに cd して呼ぶ。
# ⚠ gws は .m4a を application/octet-stream として上げる。tl;dv が形式を何で
#   判定しているかは不明なので、原本と同じ MIME に直しておく。
drive_upload() { # localPath parentId [mimeType] -> fileId
	local dir base out id
	dir=$(cd "$(dirname "$1")" && pwd)
	base=$(basename "$1")
	out=$(cd "$dir" && "$GWS" drive +upload "./$base" --parent "$2" 2>/dev/null)
	id=$(printf '%s' "$out" | jq -r '.id // empty')
	[ -n "$id" ] || return 1
	if [ -n "${3:-}" ]; then
		gws_drive files update \
			--params "$(jq -nc --arg i "$id" '{fileId:$i,fields:"id"}')" \
			--json "$(jq -nc --arg m "$3" '{mimeType:$m}')" >/dev/null 2>&1 || true
	fi
	printf '%s' "$id"
}

# ---------------------------------------------------------------- tl;dv API

tldv_curl() { # method path [data]
	local method=$1 path=$2 data=${3:-}
	if [ -n "$data" ]; then
		curl -sS --max-time 120 -X "$method" "$TLDV_API$path" \
			-H "x-api-key: $TLDV_API_KEY" -H 'content-type: application/json' \
			-w '\n%{http_code}' -d "$data"
	else
		curl -sS --max-time 120 -X "$method" "$TLDV_API$path" \
			-H "x-api-key: $TLDV_API_KEY" -w '\n%{http_code}'
	fi
}

# body と http code を分離して echo する: 1 行目以降=body, 最終行=code
http_body() { sed '$d'; }
http_code() { tail -n1; }

tldv_import() { # name url happenedAt -> jobId (空なら失敗)
	local name=$1 url=$2 happened=$3 body resp code parts
	# ⚠ 空文字を jq -R にパイプすると「出力なし」になり --argjson が壊れる。
	#    --arg で渡して jq 側で split する。
	parts=$(jq -nc --arg p "${TLDV_PARTICIPANTS:-}" '$p | split(",") | map(select(length>0))')
	body=$(jq -nc --arg n "$name" --arg u "$url" --arg h "$happened" \
		--argjson dry "${TLDV_DRY_RUN:-false}" \
		--argjson participants "$parts" \
		'{name:$n,url:$u}
       + (if $h == "" then {} else {happenedAt:$h} end)
       + (if $dry then {dryRun:true} else {} end)
       + (if ($participants|length) > 0 then {participants:$participants} else {} end)')
	resp=$(tldv_curl POST /meetings/import "$body")
	code=$(printf '%s' "$resp" | http_code)
	if [ "$code" != "200" ] && [ "$code" != "201" ]; then
		err import_http_error "http=$code" "body=$(printf '%s' "$resp" | http_body | head -c 300)"
		return 1
	fi
	printf '%s' "$resp" | http_body | jq -r '.jobId // empty'
}

# import の jobId は取り込み後の meeting の extraProperties.conferenceId に入る (実測)。
# 名前一致より確実なのでこれで完了を検知する。
#
# ⚠ 1 ページ (100 件) で足りるとは限らない。再送 (resend.sh) の重複チェックは
#   数日前の createdTime から引くので、その間の会議が 100 件を超えうる。
#   「見つからなかった」と「ページの外に居た」を混同しないよう pages を辿る。
TLDV_MAX_PAGES=${TLDV_MAX_PAGES:-20}
tldv_find_by_jobid() { # jobId fromDate(YYYY-MM-DD) -> meeting json or empty
	local job=$1 from=$2 page=1 pages=1 resp code body hit
	while [ "$page" -le "$pages" ] && [ "$page" -le "$TLDV_MAX_PAGES" ]; do
		resp=$(tldv_curl GET "/meetings?page=$page&limit=100&from=$from")
		code=$(printf '%s' "$resp" | http_code)
		if [ "$code" != "200" ]; then
			warn meetings_http_error "http=$code" "page=$page"
			return 1
		fi
		body=$(printf '%s' "$resp" | http_body)
		hit=$(printf '%s' "$body" |
			jq -c --arg j "$job" '[.results[]? | select(.extraProperties.conferenceId == $j)][0] // empty')
		if [ -n "$hit" ]; then
			printf '%s' "$hit"
			return 0
		fi
		pages=$(printf '%s' "$body" | jq -r '.pages // 1')
		page=$((page + 1))
	done
	return 0
}

# ---------------------------------------------------------------- state

state_init() {
	mkdir -p "$INFLIGHT_DIR" "$ATTEMPT_DIR" "$SCRATCH_DIR" "$HAPPENED_DIR"
	touch "$LEDGER"
}

ledger_append() { # json
	printf '%s\n' "$1" >>"$LEDGER"
}

# 台帳の 1 行。
# ⚠ outcome だけでは再送 (resend.sh) が「諦めた job が後から届いていないか」を
#   確かめられない (jobId が要る) し、一覧にファイル名も出せない。必ずここを通す。
ledger_record() { # fileId fileName outcome [jobId] [reason]
	ledger_append "$(jq -nc \
		--arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		--arg f "$1" --arg n "${2:-}" --arg o "$3" --arg j "${4:-}" --arg r "${5:-}" \
		'{at:$t,fileId:$f,fileName:$n,outcome:$o}
       + (if $j == "" then {} else {jobId:$j} end)
       + (if $r == "" then {} else {reason:$r} end)')"
}

# 台帳から fileId の最終レコードを引く (無ければ空)
ledger_last() { # fileId -> json or empty
	[ -f "$LEDGER" ] || return 0
	jq -c --arg f "$1" 'select(.fileId == $f)' "$LEDGER" 2>/dev/null | tail -n1
}

attempts_get() { # fileId
	cat "$ATTEMPT_DIR/$1" 2>/dev/null || printf '0'
}

attempts_bump() { # fileId
	local n
	n=$(($(attempts_get "$1") + 1))
	printf '%s' "$n" >"$ATTEMPT_DIR/$1"
	printf '%s' "$n"
}

attempts_clear() { # fileId
	rm -f "$ATTEMPT_DIR/$1"
}

# 分割した断片に「元の録音の日時」を引き継ぐための控え。
# 🔴 Drive の createdTime は書き換えられない (files.update が fieldNotWritable を
#   返す) ので、断片の happenedAt は放っておくと「アップロードした時刻」になり、
#   tl;dv 上で時系列が崩れる。投入時にここを見て上書きする。
happened_set() { # fileId isoTime
	mkdir -p "$HAPPENED_DIR"
	printf '%s' "$2" >"$HAPPENED_DIR/$1"
}
happened_get() { # fileId -> isoTime or empty
	cat "$HAPPENED_DIR/$1" 2>/dev/null || true
}
happened_clear() { # fileId
	rm -f "$HAPPENED_DIR/$1"
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

ext_supported() { # filename
	local e
	e=$(lower "${1##*.}")
	case " $SUPPORTED_EXT " in
	*" $e "*) return 0 ;;
	*) return 1 ;;
	esac
}
