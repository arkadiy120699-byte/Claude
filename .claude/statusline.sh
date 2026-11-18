#!/usr/bin/env bash
# Status line for Claude Code: bars for remaining context and subscription limits.
# Reads the status-line JSON from stdin. Requires jq.
#
# Example output:
#   Opus  [████████████░░░░░░░░] 62% контекста осталось (76k/200k)  5ч [████████░░] 77% ↻ 2ч 15м  неделя [██████░░░░] 59% ↻ 3д 4ч

input=$(cat)
BAR_WIDTH=${CONTEXT_BAR_WIDTH:-20}

jqr() { printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null; }

model=$(jqr '.model.display_name')
model_id=$(jqr '.model.id')

# Context window size: from input, otherwise guess by model id.
size=$(jqr '.context_window.context_window_size')
if [ -z "$size" ] || [ "$size" = "0" ]; then
  case "$model_id" in *1m*|*1M*) size=1000000 ;; *) size=200000 ;; esac
fi

# Tokens currently in context: preferred from current_usage in the input.
used=$(jqr '.context_window.current_usage | if . then ((.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0)) else empty end')

# Fallback: usage of the last main-thread assistant message in the transcript.
if [ -z "$used" ]; then
  transcript=$(jqr '.transcript_path')
  if [ -n "$transcript" ] && [ -f "$transcript" ]; then
    used=$(tail -n 400 "$transcript" | jq -rs '
      [ .[] | select(.type == "assistant" and (.isSidechain | not) and .message.usage != null) ]
      | last | .message.usage
      | if . then ((.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0)) else empty end
    ' 2>/dev/null)
  fi
fi
used=${used:-0}

# Percent remaining: trust the value Claude Code provides, if any.
left=$(jqr '.context_window.remaining_percentage')
if [ -n "$left" ]; then
  left=$(printf '%.0f' "$left")
else
  left=$(( 100 - used * 100 / size ))
fi
(( left < 0 )) && left=0
(( left > 100 )) && left=100

dim=$'\033[2m'; reset=$'\033[0m'

# Colour by percent remaining: green > 50%, yellow > 20%, red otherwise.
color_for() {
  if   (( $1 > 50 )); then printf '\033[32m'
  elif (( $1 > 20 )); then printf '\033[33m'
  else                     printf '\033[31m'
  fi
}

# bar <percent_left> <width>
bar() {
  local f=$(( $1 * $2 / 100 )) out="" i
  for ((i = 0; i < f; i++));  do out+="█"; done
  for ((i = f; i < $2; i++)); do out+="░"; done
  printf '%s' "$out"
}

fmt_k() { awk -v n="$1" 'BEGIN { if (n >= 1000000) printf "%.1fM", n/1000000; else printf "%dk", n/1000 }'; }

# Time until a unix timestamp: "2ч 15м", "3д 4ч", "12м".
until_ts() {
  local d=$(( $1 - $(date +%s) ))
  (( d < 0 )) && d=0
  local days=$(( d / 86400 )) h=$(( d % 86400 / 3600 )) m=$(( d % 3600 / 60 ))
  if   (( days > 0 )); then printf '%dд %dч' "$days" "$h"
  elif (( h > 0 ));    then printf '%dч %dм' "$h" "$m"
  else                      printf '%dм' "$m"
  fi
}

# --- Context ---
c=$(color_for "$left")
line=$(printf '%s[%s%s%s] %s%d%%%s контекста осталось %s(%s/%s)%s' \
  "${model:+$model  }" "$c" "$(bar "$left" "$BAR_WIDTH")" "$reset" \
  "$c" "$left" "$reset" "$dim" "$(fmt_k "$used")" "$(fmt_k "$size")" "$reset")

# --- Subscription limits (only Pro/Max/Ultra, after the first API response) ---
LIMIT_BAR_WIDTH=${LIMIT_BAR_WIDTH:-10}
limit_segment() {   # <json key> <label>
  local pct reset_at lim cc extra=""
  pct=$(jqr ".rate_limits.$1.used_percentage")
  [ -z "$pct" ] && return
  reset_at=$(jqr ".rate_limits.$1.resets_at")
  lim=$(( 100 - $(printf '%.0f' "$pct") ))
  (( lim < 0 )) && lim=0
  if [ "$1" = "spend_limit" ]; then
    local u l
    u=$(jqr '.rate_limits.spend_limit.used_usd'); l=$(jqr '.rate_limits.spend_limit.limit_usd')
    [ -n "$u" ] && [ -n "$l" ] && extra=$(printf ' $%.0f/$%.0f' "$u" "$l")
  fi
  cc=$(color_for "$lim")
  printf '  %s%s%s [%s%s%s] %s%d%%%s%s' "$dim" "$2" "$reset" \
    "$cc" "$(bar "$lim" "$LIMIT_BAR_WIDTH")" "$reset" "$cc" "$lim" "$reset" "$extra"
  [ -n "$reset_at" ] && printf ' %s↻ %s%s' "$dim" "$(until_ts "$reset_at")" "$reset"
}

line+=$(limit_segment five_hour "5ч")
line+=$(limit_segment seven_day "неделя")
line+=$(limit_segment spend_limit "бюджет")

printf '%s' "$line"
