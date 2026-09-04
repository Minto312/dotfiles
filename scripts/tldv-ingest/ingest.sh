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
# 🔴 これを超える尺は tl;dv が沈黙して取り込まない (実測: 145 分は通り 190 分は
#    落ちる)。既定は「実際に通ったいちばん長い尺」に置いてある。
MAX_DURATION=${TLDV_MAX_DURATION:-8700}

setup_gws
state_init

exec 9>"$STATE_DIR/ingest.lock"
if ! flock -n 9; then
	info skipped reason=already_running
	exit 0
fi

# 分割の作業ディレクトリは 1 実行の中でしか使わない (flock で同時実行はしない)。
# ⚠ SIGKILL では trap も走らないので、開始時にも消しておく — / が逼迫している
#   のに原本 + 断片ぶんが残り続けるのは避けたい。
rm -rf "$SPLIT_DIR"

# 🔴 投入の途中で落ちるとファイルが公開のまま残る。実際に踏んだ (分割の空き容量
#    チェックが df の指定ミスで死に、共有を足した直後で止まった)。この仕組みは
#    「公開ウィンドウが数分で閉じる」ことが前提なので、開けっぱなしは最悪の壊れ方。
#    今まさにこちらが公開している 1 件を控え、どう終わっても必ず剥がす。
SHARED_FILE=''
SHARED_PERM=''
mark_shared() { # fileId permId
	SHARED_FILE=$1
	SHARED_PERM=$2
}
# 剥がし終えた / inflight に引き継いだので、もう見張らなくてよい
release_shared() {
	SHARED_FILE=''
	SHARED_PERM=''
}
cleanup_share() {
	rm -rf "$SPLIT_DIR"
	[ -n "$SHARED_FILE" ] || return 0
	warn unshare_on_exit "file_id=$SHARED_FILE" "perm_id=$SHARED_PERM" \
		"note=処理が途中で終わったので公開を剥がす"
	drive_unshare "$SHARED_FILE" "$SHARED_PERM" || true
	release_shared
}
# ⚠ EXIT trap だけでは SIGTERM で走らない。systemd は TimeoutStartSec を超えると
#   TERM を送ってくる (分割はダウンロード + ffmpeg + アップロードで時間を食う) ので、
#   TERM / INT / HUP も捕まえないと「時間切れで殺されて公開が残る」が起きる。
trap cleanup_share EXIT
trap 'cleanup_share; exit 143' TERM
trap 'cleanup_share; exit 130' INT
trap 'cleanup_share; exit 129' HUP

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
	happened_clear "$1"
	# failed/ を見ただけでは「再送すれば通るのか、直しても通らないのか」が
	# 分からない。理由を台帳に残して resend.sh の一覧に出す。
	ledger_record "$1" "$2" rejected "" "$3"
}

# 🔴 約 3 時間を超える音声は tl;dv が沈黙して取り込まない
#    (import は 200 と jobId を返すのに会議が永久に現れない。services/tldv-ingest.md)。
#    投入前に分割する。**ここだけはバイト列が develop を通る**。
split_one() { # fileId fileName url duration mimeType createdTime -> 0 なら断片を inbox に置いた
	local file_id=$1 file_name=$2 url=$3 dur=$4 mime=$5 created=$6
	local base ext parts chunk i work part new_id src rc=1 need avail epoch

	if ! command -v ffmpeg >/dev/null 2>&1; then
		err split_unavailable "$(q file "$file_name")" "file_id=$file_id" "dur=${dur}s" \
			"note=ffmpeg が無いので分割できない"
		return 1
	fi

	ext=${file_name##*.}
	base=${file_name%.*}
	parts=$(((dur + MAX_DURATION - 1) / MAX_DURATION))
	chunk=$(((dur + parts - 1) / parts))
	work="$SPLIT_DIR/$file_id"
	src="$work/src.$ext"

	# ⚠ / が逼迫しているので、原本 + 断片ぶんの空きを先に確かめる (無いと途中で死ぬ)
	need=$(curl -sSI -L --max-time 60 "$url" 2>/dev/null |
		tr -d '\r' | awk -F': ' 'tolower($1)=="content-length"{n=$2} END{print n+0}')
	avail=$(($(df -k --output=avail "$STATE_DIR" | tail -1) * 1024))
	if [ "$need" -gt 0 ] && [ "$avail" -lt $((need * 3)) ]; then
		err split_no_space "$(q file "$file_name")" "file_id=$file_id" \
			"need=$((need * 3))" "avail=$avail"
		return 1
	fi

	rm -rf "$work"
	mkdir -p "$work"

	if curl -sS -L --max-time 1800 -o "$src" "$url"; then
		rc=0
		for i in $(seq 1 "$parts"); do
			part="$work/${base}_${i}of${parts}.${ext}"
			# -c copy なので再エンコードしない (音質は原本のまま)
			if ! ffmpeg -v error -ss "$(((i - 1) * chunk))" -t "$chunk" -i "$src" \
				-c copy -avoid_negative_ts make_zero "$part" 2>/dev/null; then
				err split_failed "$(q file "$file_name")" "file_id=$file_id" "part=$i/$parts"
				rc=1
				break
			fi
			new_id=$(drive_upload "$part" "$TLDV_INBOX_FOLDER_ID" "$mime") || new_id=''
			if [ -z "$new_id" ]; then
				err split_upload_failed "$(q file "$file_name")" "part=$i/$parts"
				rc=1
				break
			fi
			# 元の録音日時 + 断片の開始位置を控える (createdTime は書き換えられない)
			epoch=$(date -u -d "$created" +%s 2>/dev/null || printf '')
			if [ -n "$epoch" ]; then
				happened_set "$new_id" \
					"$(date -u -d "@$((epoch + (i - 1) * chunk))" +%Y-%m-%dT%H:%M:%S.000Z)"
			fi
			info split_part "$(q file "$(basename "$part")")" "file_id=$new_id" \
				"part=$i/$parts" "seconds=$chunk"
		done
	else
		err split_download_failed "$(q file "$file_name")" "file_id=$file_id"
	fi

	rm -rf "$work"
	[ "$rc" -eq 0 ] || return 1
	info split "$(q file "$file_name")" "file_id=$file_id" "dur=${dur}s" "parts=$parts" \
		"note=断片を inbox に置いた。次の実行で投入される"
	return 0
}

submit_one() { # fileId fileName size createdTime mimeType
	local file_id=$1 file_name=$2 size=$3 created=$4 mime=${5:-}
	local perm_id='' shared_by_us=0 url probe job name attempts dur happened

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
		mark_shared "$file_id" "$perm_id"
	fi

	url=$(public_media_url "$file_id")

	# ⚠ ここが本質的な検査。webContentLink や 100MB 超の確認ページを掴んでいないかを
	#    未認証で確かめてから tl;dv に渡す。
	if ! probe=$(verify_public_media "$url"); then
		[ "$shared_by_us" -eq 1 ] && { drive_unshare "$file_id" "$perm_id" || true; }
		release_shared
		attempts_bump "$file_id" >/dev/null
		err probe_failed "$(q file "$file_name")" "file_id=$file_id" "$probe"
		return
	fi

	# 🔴 尺が長すぎるものは投入せず分割する (投入しても沈黙で失敗するだけ)
	if dur=$(media_duration "$url"); then
		if [ "$dur" -gt "$MAX_DURATION" ]; then
			if split_one "$file_id" "$file_name" "$url" "$dur" "$mime" "$created"; then
				[ "$shared_by_us" -eq 1 ] && { drive_unshare "$file_id" "$perm_id" || true; }
				release_shared
				drive_move "$file_id" "$TLDV_INBOX_FOLDER_ID" "$TLDV_DONE_FOLDER_ID" ||
					warn move_failed "file_id=$file_id"
				ledger_record "$file_id" "$file_name" split
				attempts_clear "$file_id"
				return
			fi
			[ "$shared_by_us" -eq 1 ] && { drive_unshare "$file_id" "$perm_id" || true; }
			release_shared
			reject "$file_id" "$file_name" "too_long=${dur}s (分割できなかった)"
			return
		fi
	else
		warn duration_unknown "$(q file "$file_name")" "file_id=$file_id" \
			"note=尺を確認できないので長さの判定を飛ばす"
	fi

	name=${file_name%.*}
	# 分割の断片は createdTime が「上げた時刻」なので、控えてある元の日時を使う
	happened=$(happened_get "$file_id")
	[ -n "$happened" ] || happened=$created
	if ! job=$(tldv_import "$name" "$url" "$happened"); then
		[ "$shared_by_us" -eq 1 ] && { drive_unshare "$file_id" "$perm_id" || true; }
		release_shared
		attempts_bump "$file_id" >/dev/null
		err import_failed "$(q file "$file_name")" "file_id=$file_id" "attempts=$((attempts + 1))"
		return
	fi

	if [ "${TLDV_DRY_RUN:-false}" = "true" ]; then
		[ "$shared_by_us" -eq 1 ] && { drive_unshare "$file_id" "$perm_id" || true; }
		release_shared
		info dry_run_ok "$(q file "$file_name")" "file_id=$file_id" "job_id=$job" \
			"size=$size" "$probe" "note=ファイルは inbox に残す"
		return
	fi

	jq -nc --arg f "$file_id" --arg n "$file_name" --arg j "$job" \
		--arg p "${perm_id:-}" --argjson s "$(date +%s)" --arg sz "$size" \
		'{fileId:$f,fileName:$n,jobId:$j,permissionId:$p,submittedAt:$s,size:$sz}' \
		>"$INFLIGHT_DIR/$file_id.json"
	# ここから先は刈り取りフェーズが公開の解除を担当する
	release_shared

	drive_move "$file_id" "$TLDV_INBOX_FOLDER_ID" "$TLDV_DONE_FOLDER_ID" ||
		warn move_failed "file_id=$file_id" "note=次回実行で二重投入しないよう inflight で抑止済み"

	happened_clear "$file_id"
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
		submit_one "$file_id" "$file_name" "$size" "$created" "$mime" ||
			warn submit_failed "file_id=$file_id"
	done < <(printf '%s' "$listing" |
		jq -r '.files[]? | [.id,.name,.mimeType,(.size//"null"),.createdTime,.modifiedTime] | @tsv')
}

# ---------------------------------------------------------------- main

preflight
reap_all
submit_new
info run_finished
