#!/usr/bin/env bash
# Claude Code statusLine: 2 行で識別系 + 使用量系を表示
#
# stdin: settings.json の statusLine 仕様で渡される JSON
# stdout: 各行が 1 行として表示される

set -uo pipefail

input=$(cat)

# --- ANSI ---
RESET=$'\033[0m'
BOLD=$'\033[1m'
RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
BLUE=$'\033[34m'
MAGENTA=$'\033[35m'
CYAN=$'\033[36m'
GRAY=$'\033[90m'

# --- 1 度の jq で必要フィールドを 1 行 1 値で抽出 ---
# (タブ区切り + read -r は IFS が whitespace なため空フィールドが潰れる罠を回避)
{
  IFS= read -r model
  IFS= read -r cwd
  IFS= read -r project_dir
  IFS= read -r worktree
  IFS= read -r output_style
  IFS= read -r vim_mode
  IFS= read -r agent_name
  IFS= read -r ctx_pct
  IFS= read -r cost
  IFS= read -r dur_ms
  IFS= read -r lines_add
  IFS= read -r lines_del
  IFS= read -r rl5_pct
  IFS= read -r rl5_resets
  IFS= read -r rl7_pct
  IFS= read -r rl7_resets
} < <(jq -r '
  (.model.display_name // ""),
  (.workspace.current_dir // ""),
  (.workspace.project_dir // ""),
  (.workspace.git_worktree // ""),
  (.output_style.name // ""),
  (.vim.mode // ""),
  (.agent.name // ""),
  ((.context_window.used_percentage // 0) | floor),
  (.cost.total_cost_usd // 0),
  ((.cost.total_duration_ms // 0) | floor),
  ((.cost.total_lines_added // 0) | floor),
  ((.cost.total_lines_removed // 0) | floor),
  ((.rate_limits.five_hour.used_percentage // 0) | floor),
  (.rate_limits.five_hour.resets_at // ""),
  ((.rate_limits.seven_day.used_percentage // 0) | floor),
  (.rate_limits.seven_day.resets_at // "")
' <<<"$input")

# --- ヘルパー ---
short_path() { local p="$1"; printf '%s' "${p/#$HOME/~}"; }

pct_color() {
  local v="${1:-0}"
  if   (( v < 50 )); then printf '%s' "$GREEN"
  elif (( v < 80 )); then printf '%s' "$YELLOW"
  else                    printf '%s' "$RED"
  fi
}

model_color() {
  case "$1" in
    *Opus*)   printf '%s' "$MAGENTA" ;;
    *Sonnet*) printf '%s' "$BLUE" ;;
    *Haiku*)  printf '%s' "$GREEN" ;;
    *)        printf '%s' "$CYAN" ;;
  esac
}

fmt_dur() {
  local s=$(( ${1:-0} / 1000 ))
  if   (( s < 60 ));   then printf '%ds' "$s"
  elif (( s < 3600 )); then printf '%dm%02ds' $((s/60)) $((s%60))
  else                      printf '%dh%02dm' $((s/3600)) $(((s%3600)/60))
  fi
}

git_branch() {
  [[ -z "$cwd" || ! -d "$cwd" ]] && return 0
  git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null \
    || git -C "$cwd" rev-parse --short HEAD 2>/dev/null
}

# resets_at -> 残り時間 (Xm / Xh YYm / Xd YYh)
# 入力は Unix epoch 整数 (実測値) でも ISO8601 文字列でも OK
fmt_remaining() {
  local target="$1"
  [[ -z "$target" ]] && return 0
  local now ts diff
  now=$(date +%s)
  if [[ "$target" =~ ^[0-9]+$ ]]; then
    ts="$target"
  else
    ts=$(date -d "$target" +%s 2>/dev/null) || return 0
  fi
  diff=$((ts - now))
  (( diff <= 0 )) && return 0
  if   (( diff < 3600 ));  then printf '%dm' $((diff/60))
  elif (( diff < 86400 )); then printf '%dh%02dm' $((diff/3600)) $(((diff%3600)/60))
  else                          printf '%dd%02dh' $((diff/86400)) $(((diff%86400)/3600))
  fi
}

# --- コストキャッシュ (today / 過去 30 日) ---
# ccusage は ~3.5 秒 / 4.4 CPU 秒かかるため TTL 30 分でキャッシュし、
# 古ければ statusLine 内からバックグラウンドで更新を発火 (fire-and-forget)。
COST_CACHE="$HOME/.claude/cache/cost-summary.json"
COST_TTL=1800
cost_today="—" cost_30d="—"
if [[ -r "$COST_CACHE" ]]; then
  read -r cost_today cost_30d cache_ts < <(
    jq -r '"\(.today // 0) \(.last_30d // 0) \(.updated_at // 0)"' "$COST_CACHE" 2>/dev/null
  )
  age=$(( $(date +%s) - ${cache_ts:-0} ))
else
  age=$COST_TTL  # キャッシュ無し → 即更新トリガ
fi
if (( age >= COST_TTL )); then
  ( setsid bash "$HOME/.claude/scripts/cost-update.sh" >/dev/null 2>&1 < /dev/null & ) 2>/dev/null
fi

# --- 組み立て ---
mc=$(model_color "$model")
ctx_c=$(pct_color "$ctx_pct")
rl5_c=$(pct_color "$rl5_pct")
rl7_c=$(pct_color "$rl7_pct")

cwd_short=$(short_path "$cwd")
branch=$(git_branch)
sep=" ${GRAY}|${RESET} "

# コスト整形 (キャッシュ未生成のときは "—")
fmt_cost() {
  local v="$1"
  [[ "$v" == "—" || -z "$v" ]] && { printf '%s' "—"; return; }
  printf '$%.2f' "$v"
}

# Line 1: identity
line1="${mc}${BOLD}${model:-?}${RESET}${sep}${CYAN}${cwd_short}${RESET}"
[[ -n "$branch" ]] && line1+=" ${GRAY}@${RESET} ${YELLOW}${branch}${RESET}"
if [[ -n "$worktree" && "$worktree" != "$project_dir" ]]; then
  line1+=" ${GRAY}wt:${RESET}$(basename "$worktree")"
fi
[[ -n "$output_style" && "$output_style" != "default" ]] && line1+="${sep}${MAGENTA}${output_style}${RESET}"
[[ -n "$agent_name" ]] && line1+="${sep}${GREEN}@${agent_name}${RESET}"
[[ -n "$vim_mode"   ]] && line1+=" ${GRAY}[${RESET}${vim_mode}${GRAY}]${RESET}"

# Line 2: usage
line2="${GRAY}ctx${RESET} ${ctx_c}${ctx_pct}%${RESET}"
line2+="${sep}${GRAY}5h${RESET} ${rl5_c}${rl5_pct}%${RESET}"
rem5=$(fmt_remaining "$rl5_resets")
[[ -n "$rem5" ]] && line2+=" ${GRAY}(${rem5})${RESET}"
line2+="${sep}${GRAY}7d${RESET} ${rl7_c}${rl7_pct}%${RESET}"
rem7=$(fmt_remaining "$rl7_resets")
[[ -n "$rem7" ]] && line2+=" ${GRAY}(${rem7})${RESET}"
# コスト: session / 1day / 30d
line2+="${sep}${GRAY}sess${RESET} $(fmt_cost "$cost")"
line2+=" ${GRAY}/ 1d${RESET} $(fmt_cost "$cost_today")"
line2+=" ${GRAY}/ 30d${RESET} $(fmt_cost "$cost_30d")"
if (( lines_add > 0 || lines_del > 0 )); then
  line2+="${sep}${GREEN}+${lines_add}${RESET}/${RED}-${lines_del}${RESET}"
fi

printf '%s\n%s\n' "$line1" "$line2"
