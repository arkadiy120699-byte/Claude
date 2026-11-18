#!/usr/bin/env bash
# Status line for Claude Code: bars for remaining context and subscription limits.
# Reads the status-line JSON from stdin. Requires jq.
#
# Example output:
#   Контекст         ████████████░░░░░░░░  осталось  62%  занято 76k из 200k токенов
#   Лимит на 5 часов ███████████████░░░░░  осталось  76%  обновится через 2 ч 15 мин
#   Лимит на неделю  ███░░░░░░░░░░░░░░░░░  осталось  15%  обновится через 3 дн 4 ч

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

# Time until reset in plain words: "2 ч 15 мин", "3 дн 4 ч", "12 мин".
until_words() {
  local d=$(( $1 - $(date +%s) ))
  (( d < 0 )) && d=0
  local days=$(( d / 86400 )) h=$(( d % 86400 / 3600 )) m=$(( d % 3600 / 60 ))
  if   (( days > 0 )); then printf '%d дн %d ч' "$days" "$h"
  elif (( h > 0 ));    then printf '%d ч %d мин' "$h" "$m"
  else                      printf '%d мин' "$m"
  fi
}

# row <label> <percent_left> <comment>
row() {
  local cc; cc=$(color_for "$2")
  printf '%s %s%s%s  %sосталось %3d%%%s  %s%s%s\n' \
    "$1" "$cc" "$(bar "$2" "$BAR_WIDTH")" "$reset" "$cc" "$2" "$reset" "$dim" "$3" "$reset"
}

# --- Context ---
out=$(row "Контекст        " "$left" "занято $(fmt_k "$used") из $(fmt_k "$size") токенов")

# --- Subscription limits (only Pro/Max/Ultra, after the first API response) ---
limit_row() {   # <json key> <label>
  local pct reset_at lim note=""
  pct=$(jqr ".rate_limits.$1.used_percentage")
  [ -z "$pct" ] && return
  lim=$(( 100 - $(printf '%.0f' "$pct") ))
  (( lim < 0 )) && lim=0
  if [ "$1" = "spend_limit" ]; then
    local u l
    u=$(jqr '.rate_limits.spend_limit.used_usd'); l=$(jqr '.rate_limits.spend_limit.limit_usd')
    [ -n "$u" ] && [ -n "$l" ] && note=$(printf 'потрачено $%.0f из $%.0f, ' "$u" "$l")
  fi
  reset_at=$(jqr ".rate_limits.$1.resets_at")
  [ -n "$reset_at" ] && note+="обновится через $(until_words "$reset_at")"
  printf '\n'; row "$2" "$lim" "$note"
}

out+=$(limit_row five_hour   "Лимит на 5 часов")
out+=$(limit_row seven_day   "Лимит на неделю ")
out+=$(limit_row spend_limit "Бюджет          ")

printf '%s\n' "$out"
