#!/usr/bin/env bash
# Status line for Claude Code: a bar showing how much context window is left.
# Reads the status-line JSON from stdin. Requires jq.
#
# Example output:  Opus  [████████████░░░░░░░░] 62% контекста осталось (76k/200k)

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

# Colour: green > 50%, yellow > 20%, red otherwise.
if   (( left > 50 )); then color=$'\033[32m'
elif (( left > 20 )); then color=$'\033[33m'
else                       color=$'\033[31m'
fi
dim=$'\033[2m'; reset=$'\033[0m'

filled=$(( left * BAR_WIDTH / 100 ))
empty=$(( BAR_WIDTH - filled ))
bar=""
for ((i = 0; i < filled; i++)); do bar+="█"; done
for ((i = 0; i < empty; i++));  do bar+="░"; done

fmt_k() { awk -v n="$1" 'BEGIN { if (n >= 1000000) printf "%.1fM", n/1000000; else printf "%dk", n/1000 }'; }

printf '%s[%s%s%s] %s%d%%%s контекста осталось %s(%s/%s)%s' \
  "${model:+$model  }" "$color" "$bar" "$reset" \
  "$color" "$left" "$reset" "$dim" "$(fmt_k "$used")" "$(fmt_k "$size")" "$reset"
