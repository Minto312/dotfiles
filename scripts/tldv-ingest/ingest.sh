#!/usr/bin/env bash
# Google Drive の受け皿フォルダに置かれた音声/動画を tl;dv に取り込む。
#
# 1 回の実行で 2 フェーズを回す:
#   A. 取り込み中 (inflight) のものを刈る … 完了検知 → 公開権限を剥がす
#   B. 新しいファイルを投入する         … 公開権限を足す → import → done/ へ退避
#
# systemd timer から数分おきに叩かれる前提。詳細は machine/services/tldv-ingest.md
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

ENV_FILE=${TLDV_ENV_FILE:-$HOME/.config/tldv-ingest/env}
if [ ! -f "$ENV_FILE" ]; then
	printf 'error: %s が無い (env.example を参照)\n' "$ENV_FILE" >&2
	exit 1
fi
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

# shellcheck source=./lib.sh
. "$HERE/lib.sh"

# dryRun は jq に真偽値として渡すので true/false に正規化する
case "$(printf '%s' "${TLDV_DRY_RUN:-}" | tr '[:upper:]' '[:lower:]')" in
1 | true | yes | on) TLDV_DRY_RUN=true ;;
*) TLDV_DRY_RUN=false ;;
esac

MAX_PER_RUN=${TLDV_MAX_PER_RUN:-3}
MAX_ATTEMPTS=${TLDV_MAX_ATTEMPTS:-3}
GRACE_SECONDS=${TLDV_GRACE_SECONDS:-90}
IMPORT_TIMEOUT=${TLDV_IMPORT_TIMEOUT:-3600}

setup_gws
state_init

exec 9>"$STATE_DIR/ingest.lock"
if ! flock -n 9; then
	info skipped reason=already_running
	exit 0
fi

# ---------------------------------------------------------------- preflight

preflight() {
	local missing=0 v
	for v in TLDV_API_KEY TLDV_INBOX_FOLDER_ID TLDV_DONE_FOLDER_ID TLDV_FAILED_FOLDER_ID; do
		if [ -z "${!v:-}" ]; then
			err config_missing "key=$v"
			missing=1
		fi
	done
	[ "$missing" -eq 0 ] || exit 1

	local resp code
	resp=$(tldv_curl GET '/meetings?page=1&limit=1') || {
		err tldv_unreachable
		exit 1
	}
	code=$(printf '%s' "$resp" | http_code)
	if [ "$code" != "200" ]; then
		err tldv_auth_failed "http=$code" "hint=API は Pro/Business プラン限定。キーを確認する"
		exit 1
	fi

	# Drive 側の疎通と受け皿フォルダの存在を 1 回で確かめる。
	# ⚠ gws は refresh token が Workspace のセッション制御で切れることがある (dev/gws.md)
	local folder
	folder=$(drive_file_get "$TLDV_INBOX_FOLDER_ID" 'id,name' | jq -r '.id // empty') || true
	if [ -z "$folder" ]; then
		err drive_unreachable "folder=$TLDV_INBOX_FOLDER_ID" \
			"hint=gws auth status を見る。再認証は gws auth login --scopes ... (dev/gws.md)"
		exit 1
	fi
}

# ---------------------------------------------------------------- phase A: reap

finalize() { # fileId permId outcome fileName jobId
	local file_id=$1 perm_id=$2 outcome=$3 file_name=${4:-} job_id=${5:-}
	if [ -n "$perm_id" ]; then
		drive_unshare "$file_id" "$perm_id" || warn unshare_failed "file_id=$file_id" "perm_id=$perm_id"
	fi
	rm -f "$INFLIGHT_DIR/$file_id.json"
	# ⚠ jobId をここで残さないと、再送 (resend.sh) が「諦めた job が後から
	#   届いていないか」を確かめられず、消せない重複会議を作ってしまう。
	ledger_record "$file_id" "$file_name" "$outcome" "$job_id"
}

reap_one() { # inflight json path
	local rec file_id file_name job_id submitted perm_id meeting from age
	rec=$(cat "$1")
	file_id=$(printf '%s' "$rec" | jq -r '.fileId')
	file_name=$(printf '%s' "$rec" | jq -r '.fileName')
	job_id=$(printf '%s' "$rec" | jq -r '.jobId // ""')
	submitted=$(printf '%s' "$rec" | jq -r '.submittedAt')
	perm_id=$(printf '%s' "$rec" | jq -r '.permissionId // ""')
	age=$(($(date +%s) - submitted))

	from=$(date -u -d "@$((submitted - 86400))" +%F)
	meeting=$(tldv_find_by_jobid "$job_id" "$from") || meeting=""

	if [ -n "$meeting" ]; then
		info imported \
			"$(q file "$file_name")" "file_id=$file_id" "job_id=$job_id" \
			"meeting_id=$(printf '%s' "$meeting" | jq -r '.id')" \
			"duration=$(printf '%s' "$meeting" | jq -r '.duration')" \
			"took=${age}s"
		# 投入時の移動が失敗していた場合ここで確実に inbox から出す。
		# (inflight を消したあとに inbox に残っていると次回に二重投入される)
		drive_ensure_parent "$file_id" "$TLDV_DONE_FOLDER_ID" ||
			warn move_failed "file_id=$file_id" "note=inbox に残っている可能性。手で done/ へ移す"
		finalize "$file_id" "$perm_id" imported "$file_name" "$job_id"
		attempts_clear "$file_id"
		return
	fi

	if [ "$age" -gt "$IMPORT_TIMEOUT" ]; then
		err import_timeout "$(q file "$file_name")" "file_id=$file_id" "job_id=$job_id" "age=${age}s"
		finalize "$file_id" "$perm_id" timeout "$file_name" "$job_id"
		drive_ensure_parent "$file_id" "$TLDV_FAILED_FOLDER_ID" ||
			warn move_failed "file_id=$file_id"
		return
	fi

	info waiting "$(q file "$file_name")" "file_id=$file_id" "job_id=$job_id" "age=${age}s"
}

reap_all() {
	local f
	shopt -s nullglob
	for f in "$INFLIGHT_DIR"/*.json; do
		reap_one "$f" || warn reap_failed "path=$f"
	done
	shopt -u nullglob
}

# ---------------------------------------------------------------- phase B: submit

reject() { # fileId fileName reason
	err rejected "$(q file "$2")" "file_id=$1" "reason=$3"
	drive_move "$1" "$TLDV_INBOX_FOLDER_ID" "$TLDV_FAILED_FOLDER_ID" ||
		warn move_failed "file_id=$1"
	attempts_clear "$1"
	# failed/ を見ただけでは「再送すれば通るのか、直しても通らないのか」が
	# 分からない。理由を台帳に残して resend.sh の一覧に出す。
	ledger_record "$1" "$2" rejected "" "$3"
}

submit_one() { # fileId fileName size createdTime
	local file_id=$1 file_name=$2 size=$3 created=$4
	local perm_id='' shared_by_us=0 url probe job name attempts

	if ! ext_supported "$file_name"; then
		reject "$file_id" "$file_name" "unsupported_extension (対応: $SUPPORTED_EXT)"
		return
	fi

	attempts=$(attempts_get "$file_id")
	if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
		reject "$file_id" "$file_name" "too_many_attempts=$attempts"
		return
	fi

	if drive_is_public "$file_id"; then
		# 利用者が既に公開しているファイル。こちらで剥がしてはいけない。
		warn already_public "$(q file "$file_name")" "file_id=$file_id" \
			"note=既存の公開設定はこちらでは変更しない"
	else
		perm_id=$(drive_share_public "$file_id") || perm_id=''
		if [ -z "$perm_id" ]; then
			attempts_bump "$file_id" >/dev/null
			err share_failed "$(q file "$file_name")" "file_id=$file_id" \
				"hint=Workspace 管理側で「リンクを知る全員」への共有が禁止されている可能性"
			return
		fi
		shared_by_us=1
	fi

	url=$(public_media_url "$file_id")

	# ⚠ ここが本質的な検査。webContentLink や 100MB 超の確認ページを掴んでいないかを
	#    未認証で確かめてから tl;dv に渡す。
	if ! probe=$(verify_public_media "$url"); then
		[ "$shared_by_us" -eq 1 ] && { drive_unshare "$file_id" "$perm_id" || true; }
		attempts_bump "$file_id" >/dev/null
		err probe_failed "$(q file "$file_name")" "file_id=$file_id" "$probe"
		return
	fi

	name=${file_name%.*}
	if ! job=$(tldv_import "$name" "$url" "$created"); then
		[ "$shared_by_us" -eq 1 ] && { drive_unshare "$file_id" "$perm_id" || true; }
		attempts_bump "$file_id" >/dev/null
		err import_failed "$(q file "$file_name")" "file_id=$file_id" "attempts=$((attempts + 1))"
		return
	fi

	if [ "${TLDV_DRY_RUN:-false}" = "true" ]; then
		[ "$shared_by_us" -eq 1 ] && { drive_unshare "$file_id" "$perm_id" || true; }
		info dry_run_ok "$(q file "$file_name")" "file_id=$file_id" "job_id=$job" \
			"size=$size" "$probe" "note=ファイルは inbox に残す"
		return
	fi

	jq -nc --arg f "$file_id" --arg n "$file_name" --arg j "$job" \
		--arg p "${perm_id:-}" --argjson s "$(date +%s)" --arg sz "$size" \
		'{fileId:$f,fileName:$n,jobId:$j,permissionId:$p,submittedAt:$s,size:$sz}' \
		>"$INFLIGHT_DIR/$file_id.json"

	drive_move "$file_id" "$TLDV_INBOX_FOLDER_ID" "$TLDV_DONE_FOLDER_ID" ||
		warn move_failed "file_id=$file_id" "note=次回実行で二重投入しないよう inflight で抑止済み"

	info submitted "$(q file "$file_name")" "file_id=$file_id" "job_id=$job" \
		"size=$size" "$probe"
}

submit_new() {
	local listing count=0 line file_id file_name size created modified mime now age

	listing=$(drive_files_list \
		"'$TLDV_INBOX_FOLDER_ID' in parents and trashed=false" \
		'files(id,name,mimeType,size,createdTime,modifiedTime)') || {
		err list_failed
		return 1
	}

	now=$(date +%s)
	while IFS=$'\t' read -r file_id file_name mime size created modified; do
		[ -n "$file_id" ] || continue
		[ "$mime" = 'application/vnd.google-apps.folder' ] && continue
		# Google ドキュメント類 (size を持たない) は対象外
		[ "$size" = 'null' ] && {
			info skipped "$(q file "$file_name")" reason=no_binary_content
			continue
		}
		[ -f "$INFLIGHT_DIR/$file_id.json" ] && continue

		# アップロード途中/コピー途中のものを掴まないための猶予。
		# ⚠ modifiedTime は「共有権限を足す」だけでも更新されるので使えない
		#   (自分の操作で猶予が延びて永久に投入されなくなる)。createdTime を見る。
		age=$((now - $(date -u -d "$created" +%s)))
		if [ "$age" -lt "$GRACE_SECONDS" ]; then
			info deferred "$(q file "$file_name")" "age=${age}s" "grace=${GRACE_SECONDS}s" \
				"modified=$modified"
			continue
		fi

		if [ "$count" -ge "$MAX_PER_RUN" ]; then
			info deferred "$(q file "$file_name")" reason=max_per_run
			continue
		fi
		count=$((count + 1))
		submit_one "$file_id" "$file_name" "$size" "$created" || warn submit_failed "file_id=$file_id"
	done < <(printf '%s' "$listing" |
		jq -r '.files[]? | [.id,.name,.mimeType,(.size//"null"),.createdTime,.modifiedTime] | @tsv')
}

# ---------------------------------------------------------------- main

preflight
reap_all
submit_new
info run_finished
