#!/usr/bin/env bash
# tldv-resend: tl;dv への取り込みが成立しなかったファイルを再送する。
#
# なぜ「手動」なのか (この道具の中心的な判断):
#   tl;dv の API には **import した job の状態を引く経路が無い** (実測:
#   GET /meetings/import/<jobId> は 404、GET /meetings/<jobId> は 403)。
#   完了は「GET /meetings に conferenceId == jobId の会議が現れたか」でしか分からず、
#   **現れないことと「まだ処理中」を区別できない**。
#   さらに **会議を削除する API が無い**ので、取り違えて二重投入すると
#   消せない会議が 1 つ増える (UI から手で消すしかない)。
#   この 2 つが噛み合うと「時間切れで諦めた job が後から届き、再送ぶんも届く」
#   が起きるので、既定では人間が確かめてから送る形にしてある。
#   代わりに送る前に必ず **前回の jobId の会議が後から現れていないか**を引く。
#
# 使い方:
#   tldv-resend list                  再送できるもの / 取り込み待ちを一覧する
#   tldv-resend retry <選択子>...      failed/ のファイルを inbox/ へ戻す
#   tldv-resend cancel <選択子>...     取り込み待ちを打ち切る (公開を剥がす)
#
#   選択子は file ID そのもの、またはファイル名の一部 (部分一致・大小無視)。
#   複数に当たったときは候補を出して中止する (--all を渡したときだけ一括)。
#
# 詳細は machine/services/tldv-ingest.md
set -euo pipefail

# ⚠ ~/.local/bin に symlink を張って使うので readlink -f を通す
#   (素の dirname だと symlink 自身の場所を指して lib.sh を見失う)。
HERE=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)

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

usage() {
	cat <<'EOF'
tldv-resend — tl;dv への取り込みが成立しなかったファイルを再送する

  tldv-resend list [--include-done]      再送できるもの / 取り込み待ちを一覧する
  tldv-resend retry <選択子>... [--now]  failed/ のファイルを inbox/ へ戻す
  tldv-resend cancel <選択子>...         取り込み待ちを打ち切る (公開を剥がす)

選択子は file ID そのもの、またはファイル名の一部 (部分一致・大小無視)。
複数に当たったときは候補を出して中止する。

  --all           選択子の代わりに対象すべてを選ぶ
  -y, --yes       確認プロンプトを出さない
  --now           再送後すぐ tldv-ingest.service を起動する (既定は次の timer 待ち)
  --include-done  done/ (取り込み済み) も再送の対象に含める
  --force         重複チェックに引っかかっても送る (⚠ 消せない会議が増える)

⚠ tl;dv には import job の状態を引く API も、会議を削除する API も無い。
  だから「失敗した」と「遅れている」は外から区別できず、二重投入は取り消せない。
  再送の前に必ず「前回の jobId の会議が後から現れていないか」を引く。
EOF
}

# ---------------------------------------------------------------- options

CMD=''
ASSUME_YES=0
FORCE=0
RUN_NOW=0
INCLUDE_DONE=0
SELECT_ALL=0
SELECTORS=()

while [ $# -gt 0 ]; do
	case "$1" in
	list | retry | cancel) CMD=$1 ;;
	-y | --yes) ASSUME_YES=1 ;;
	--force) FORCE=1 ;;
	--now) RUN_NOW=1 ;;
	--include-done) INCLUDE_DONE=1 ;;
	--all) SELECT_ALL=1 ;;
	-h | --help)
		usage
		exit 0
		;;
	-*)
		printf 'error: 不明なオプション %s\n\n' "$1" >&2
		usage >&2
		exit 2
		;;
	*) SELECTORS+=("$1") ;;
	esac
	shift
done
CMD=${CMD:-list}

setup_gws
state_init

for v in TLDV_API_KEY TLDV_INBOX_FOLDER_ID TLDV_DONE_FOLDER_ID TLDV_FAILED_FOLDER_ID; do
	if [ -z "${!v:-}" ]; then
		err config_missing "key=$v"
		exit 1
	fi
done

# ---------------------------------------------------------------- helpers

# 台帳の最終レコードから値を 1 つ取る (古い行は fileName / jobId を持たない)
ledger_field() { # fileId key -> value or empty
	local rec
	rec=$(ledger_last "$1") || rec=''
	[ -n "$rec" ] || return 0
	printf '%s' "$rec" | jq -r --arg k "$2" '.[$k] // ""'
}

# フォルダの中身を TSV (id, name, size, createdTime) で返す
folder_listing() { # folderId
	local listing
	listing=$(drive_files_list "'$1' in parents and trashed=false" \
		'files(id,name,mimeType,size,createdTime)') || {
		err list_failed "folder=$1"
		return 1
	}
	printf '%s' "$listing" | jq -r '.files[]?
    | select(.mimeType != "application/vnd.google-apps.folder")
    | [.id, .name, (.size // "null"), .createdTime] | @tsv'
}

human_age() { # seconds
	local s=$1
	if [ "$s" -lt 3600 ]; then
		printf '%dm' "$((s / 60))"
	elif [ "$s" -lt 86400 ]; then
		printf '%dh%dm' "$((s / 3600))" "$(((s % 3600) / 60))"
	else
		printf '%dd%dh' "$((s / 86400))" "$(((s % 86400) / 3600))"
	fi
}

confirm() { # prompt
	[ "$ASSUME_YES" -eq 0 ] || return 0
	local ans=''
	# ⚠ /dev/tty は「あって読める」ように見えても open に失敗することがある
	#   (端末を持たないセッション。実測で踏んだ)。テストしてから使う。
	if [ -t 0 ]; then
		printf '%s [y/N] ' "$1" >&2
		read -r ans || ans=''
	elif { : </dev/tty; } 2>/dev/null; then
		printf '%s [y/N] ' "$1" >&2
		read -r ans </dev/tty || ans=''
	else
		printf 'error: 端末が無いので確認できない。実行するなら -y を渡す\n' >&2
		return 1
	fi
	case "$(lower "${ans:-}")" in
	y | yes) return 0 ;;
	*)
		printf '中止した\n' >&2
		return 1
		;;
	esac
}

# 「取り込み待ち」の一覧を TSV (fileId, fileName, jobId, ageSeconds) で返す
inflight_listing() {
	local f rec now
	now=$(date +%s)
	shopt -s nullglob
	for f in "$INFLIGHT_DIR"/*.json; do
		rec=$(cat "$f")
		printf '%s' "$rec" | jq -r --argjson now "$now" \
			'[.fileId, .fileName, (.jobId // ""), ($now - .submittedAt), (.permissionId // "")] | @tsv'
	done
	shopt -u nullglob
}

# ---------------------------------------------------------------- list

cmd_list() {
	local id name job age perm out reason at size created n

	printf '取り込み待ち (inflight)\n'
	n=0
	while IFS=$'\t' read -r id name job age perm; do
		[ -n "$id" ] || continue
		n=$((n + 1))
		printf '  %s  経過 %-7s job=%s  %s\n' "$id" "$(human_age "$age")" "${job:0:18}" "$name"
	done < <(inflight_listing)
	if [ "$n" -eq 0 ]; then
		printf '  (なし)\n'
	else
		printf '  → 打ち切るなら: tldv-resend cancel <file ID または名前の一部>\n'
	fi

	printf '\nfailed/ (再送できるもの)\n'
	n=0
	while IFS=$'\t' read -r id name size created; do
		[ -n "$id" ] || continue
		n=$((n + 1))
		out=$(ledger_field "$id" outcome)
		reason=$(ledger_field "$id" reason)
		at=$(ledger_field "$id" at)
		printf '  %s  %-9s %-21s %s%s\n' "$id" "${out:-unknown}" "${at:-?}" "$name" \
			"$([ -n "$reason" ] && printf ' (%s)' "$reason")"
	done < <(folder_listing "$TLDV_FAILED_FOLDER_ID")
	if [ "$n" -eq 0 ]; then
		printf '  (なし)\n'
	else
		printf '  → 再送するなら: tldv-resend retry <file ID または名前の一部> [--now]\n'
	fi

	if [ "$INCLUDE_DONE" -eq 1 ]; then
		printf '\ndone/ (取り込み済み — 結果が壊れていたらこちらも再送できる)\n'
		n=0
		while IFS=$'\t' read -r id name size created; do
			[ -n "$id" ] || continue
			n=$((n + 1))
			out=$(ledger_field "$id" outcome)
			at=$(ledger_field "$id" at)
			printf '  %s  %-9s %-21s %s\n' "$id" "${out:-unknown}" "${at:-?}" "$name"
		done < <(folder_listing "$TLDV_DONE_FOLDER_ID")
		[ "$n" -ne 0 ] || printf '  (なし)\n'
	else
		printf '\n(done/ の取り込み済みも再送できる: --include-done)\n'
	fi
}

# ---------------------------------------------------------------- selection

# 選択子を解決して RESOLVED に "id<TAB>name<TAB>created" を並べる
RESOLVED=()
resolve() { # candidatesTSV
	local candidates=$1 sel hits id name created line lname lsel
	RESOLVED=()

	if [ "$SELECT_ALL" -eq 1 ]; then
		# ⚠ printf '%s' だと終端改行が無く、read が最後の 1 行を捨てる
		#   (command substitution が末尾の改行を落とすため)。必ず '%s\n'。
		while IFS= read -r line; do
			[ -n "$line" ] || continue
			RESOLVED+=("$line")
		done < <(printf '%s\n' "$candidates")
		if [ "${#RESOLVED[@]}" -eq 0 ]; then
			printf '対象が無い\n' >&2
			return 1
		fi
		return 0
	fi

	if [ "${#SELECTORS[@]}" -eq 0 ]; then
		printf 'error: 選択子が無い (file ID か名前の一部、または --all)\n\n' >&2
		usage >&2
		return 2
	fi

	for sel in "${SELECTORS[@]}"; do
		hits=''
		lsel=$(lower "$sel")
		while IFS=$'\t' read -r id name created; do
			[ -n "$id" ] || continue
			lname=$(lower "$name")
			if [ "$id" = "$sel" ]; then
				hits=$(printf '%s\t%s\t%s' "$id" "$name" "$created")
				break
			fi
			case "$lname" in
			*"$lsel"*) hits=$(printf '%s%s%s\t%s\t%s' "$hits" "${hits:+$'\n'}" "$id" "$name" "$created") ;;
			esac
		done < <(printf '%s\n' "$candidates")

		if [ -z "$hits" ]; then
			printf 'error: %s に当たるファイルが無い (tldv-resend list で確認する)\n' "$sel" >&2
			return 1
		fi
		if [ "$(printf '%s\n' "$hits" | wc -l)" -gt 1 ]; then
			printf 'error: %s が複数に当たった。file ID で指定する:\n' "$sel" >&2
			printf '%s\n' "$hits" | while IFS=$'\t' read -r id name created; do
				printf '  %s  %s\n' "$id" "$name" >&2
			done
			return 1
		fi
		RESOLVED+=("$hits")
	done
}

# ---------------------------------------------------------------- retry

# 「諦めた job が後から届いていないか」を確かめる。
# 届いていたら再送すると消せない重複ができるので、既定では止める。
late_arrival() { # fileId createdTime -> prints meeting json if found
	local file_id=$1 created=$2 job from meeting
	job=$(ledger_field "$file_id" jobId)
	if [ -z "$job" ]; then
		return 2 # 台帳に jobId が無い (古いレコード / 投入前に落ちた) = 確かめられない
	fi
	# happenedAt には Drive の createdTime が入る (実測) ので、そこから引く
	from=$(date -u -d "$created" +%F 2>/dev/null) || from=$(date -u -d '30 days ago' +%F)
	from=$(date -u -d "$from -1 day" +%F)
	if ! meeting=$(tldv_find_by_jobid "$job" "$from"); then
		return 3 # API が引けなかった
	fi
	[ -n "$meeting" ] || return 1
	printf '%s' "$meeting"
	return 0
}

cmd_retry() {
	local candidates rc id name created line meeting dup_name dup_id moved=0
	candidates=$(folder_listing "$TLDV_FAILED_FOLDER_ID")
	if [ "$INCLUDE_DONE" -eq 1 ]; then
		candidates=$(printf '%s\n%s' "$candidates" "$(folder_listing "$TLDV_DONE_FOLDER_ID")")
	fi
	# id, name, created の 3 列に落とす (size は使わない)
	candidates=$(printf '%s' "$candidates" | awk -F'\t' 'NF>=4 {print $1"\t"$2"\t"$4}')

	resolve "$candidates" || return $?

	for line in "${RESOLVED[@]}"; do
		IFS=$'\t' read -r id name created <<<"$line"

		# 1) 諦めた job が後から届いていないか
		if meeting=$(late_arrival "$id" "$created"); then
			printf '%s\n' "$name" >&2
			printf '  🔴 前回の job は tl;dv に**届いている** (meeting_id=%s duration=%s)\n' \
				"$(printf '%s' "$meeting" | jq -r '.id')" \
				"$(printf '%s' "$meeting" | jq -r '.duration')" >&2
			printf '     再送すると同じ会議が 2 つになる。会議を削除する API は無い。\n' >&2
			if [ "$FORCE" -eq 0 ]; then
				printf '     それでも送るなら --force\n' >&2
				continue
			fi
			printf '     --force が指定されているので続行する\n' >&2
		else
			rc=$?
			case "$rc" in
			2) printf '%s\n  ⚠ 台帳に jobId が無いので「後から届いていないか」は確かめられない\n' "$name" >&2 ;;
			3)
				printf '%s\n  ⚠ tl;dv の API が引けず重複チェックができなかった\n' "$name" >&2
				if [ "$FORCE" -eq 0 ]; then
					printf '     API が復帰してから再実行する (押し通すなら --force)\n' >&2
					continue
				fi
				;;
			esac
		fi

		# 2) 同じ名前のものが取り込み待ちに居ないか (手で再アップロードした形跡)
		while IFS=$'\t' read -r dup_id dup_name _; do
			[ -n "$dup_id" ] || continue
			[ "$dup_name" = "$name" ] || continue
			printf '  ⚠ 同じ名前が取り込み待ちに居る (file_id=%s)。両方届くと重複する\n' "$dup_id" >&2
		done < <(inflight_listing | awk -F'\t' '{print $1"\t"$2}')

		confirm "$(printf '再送する: %s (%s)' "$name" "$id")" || continue

		# 3) 状態を掃除してから inbox へ戻す。あとは既存の timer が拾う。
		#    (投入経路を分けず ingest.sh の submit フェーズを 1 本だけ通すため)
		attempts_clear "$id"
		rm -f "$INFLIGHT_DIR/$id.json"
		if ! drive_ensure_parent "$id" "$TLDV_INBOX_FOLDER_ID"; then
			err requeue_failed "$(q file "$name")" "file_id=$id" \
				"note=inbox へ戻せなかった。Drive の UI で inbox に移す"
			continue
		fi
		ledger_record "$id" "$name" requeued
		info requeued "$(q file "$name")" "file_id=$id"
		moved=$((moved + 1))
	done

	[ "$moved" -gt 0 ] || return 0
	printf '%d 件を inbox へ戻した\n' "$moved" >&2
	if [ "$RUN_NOW" -eq 1 ]; then
		run_ingest_now
	else
		printf '次の timer (5 分以内) で投入される。すぐ流すなら --now\n' >&2
	fi
}

# ⚠ 手で ingest.sh を叩くと journald に入らない (= ログも Grafana も見えない)。
#   必ず systemd 経由で起動する。
run_ingest_now() {
	if command -v systemctl >/dev/null 2>&1 &&
		systemctl --user cat tldv-ingest.service >/dev/null 2>&1; then
		printf 'tldv-ingest.service を起動する…\n' >&2
		systemctl --user start tldv-ingest.service &&
			printf '完了 (ログ: journalctl --user -u tldv-ingest.service -n 30)\n' >&2
	else
		warn unit_missing "note=systemd の unit が無いので ingest.sh を直に叩く (journald に入らない)"
		"$HERE/ingest.sh"
	fi
}

# ---------------------------------------------------------------- cancel

cmd_cancel() {
	local candidates line id name job age perm rec canceled=0
	# 取り込み待ちからは created を持たないので 3 列目は空でよい
	candidates=$(inflight_listing | awk -F'\t' '{print $1"\t"$2"\t"}')
	if [ -z "$(printf '%s' "$candidates" | tr -d '[:space:]')" ]; then
		printf '取り込み待ちは無い\n' >&2
		return 0
	fi

	resolve "$candidates" || return $?

	for line in "${RESOLVED[@]}"; do
		IFS=$'\t' read -r id name _ <<<"$line"
		rec=$(cat "$INFLIGHT_DIR/$id.json" 2>/dev/null) || rec=''
		job=$(printf '%s' "$rec" | jq -r '.jobId // ""')
		perm=$(printf '%s' "$rec" | jq -r '.permissionId // ""')

		printf '%s\n  job=%s\n' "$name" "$job" >&2
		printf '  打ち切っても tl;dv 側の job は取り消せない。公開を剥がすので、\n' >&2
		printf '  まだ取得されていなければ結果的に失敗する (取得済みなら後から届く)。\n' >&2
		confirm "$(printf '打ち切る: %s (%s)' "$name" "$id")" || continue

		if [ -n "$perm" ]; then
			drive_unshare "$id" "$perm" ||
				warn unshare_failed "file_id=$id" "perm_id=$perm"
		fi
		rm -f "$INFLIGHT_DIR/$id.json"
		# 再送 (retry) が拾えるよう failed/ へ寄せる。done/ に置いたままだと
		# 「取り込めていないのに取り込み済みの棚に居る」ことになる。
		drive_ensure_parent "$id" "$TLDV_FAILED_FOLDER_ID" ||
			warn move_failed "file_id=$id" "note=failed/ へ移せなかった"
		ledger_record "$id" "$name" canceled "$job"
		info canceled "$(q file "$name")" "file_id=$id" "job_id=$job"
		canceled=$((canceled + 1))
	done

	[ "$canceled" -eq 0 ] || printf '%d 件を打ち切った (再送は tldv-resend retry)\n' "$canceled" >&2
}

# ---------------------------------------------------------------- main

case "$CMD" in
list) cmd_list ;;
retry) cmd_retry ;;
cancel) cmd_cancel ;;
esac
