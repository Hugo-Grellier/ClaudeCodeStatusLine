#!/bin/bash
# Source: https://github.com/daniel3303/ClaudeCodeStatusLine
# Line 1: Model | Bar Used/Total (%) | effort | 5h @reset | 7d @reset | extra | duration | $cost (d/w)
# Line 2: CWD@Branch | git changes | session lines | CC update (if available)

set -f  # disable globbing

input=$(cat)

if [ -z "$input" ]; then
    printf "Claude"
    exit 0
fi

# ANSI colors matching oh-my-posh theme
blue='\033[38;2;0;153;255m'
orange='\033[38;2;255;176;85m'
green='\033[38;2;0;160;0m'
cyan='\033[38;2;46;149;153m'
red='\033[38;2;255;85;85m'
yellow='\033[38;2;230;200;0m'
white='\033[38;2;220;220;220m'
dim='\033[2m'
reset='\033[0m'

# Format token counts (e.g., 50k / 200k)
format_tokens() {
    local num=$1
    if [ "$num" -ge 1000000 ]; then
        awk "BEGIN {v=sprintf(\"%.1f\",$num/1000000)+0; if(v==int(v)) printf \"%dm\",v; else printf \"%.1fm\",v}"
    elif [ "$num" -ge 1000 ]; then
        awk "BEGIN {printf \"%.0fk\", $num / 1000}"
    else
        printf "%d" "$num"
    fi
}

# Return color escape based on usage percentage
# Usage: usage_color <pct>
usage_color() {
    local pct=$1
    if [ "$pct" -ge 90 ]; then echo "$red"
    elif [ "$pct" -ge 70 ]; then echo "$orange"
    elif [ "$pct" -ge 50 ]; then echo "$yellow"
    else echo "$green"
    fi
}

# Resolve config directory: CLAUDE_CONFIG_DIR (set by alias) or default ~/.claude
claude_config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# Return 0 (true) if $1 > $2 using semantic versioning
version_gt() {
    local a="${1#v}" b="${2#v}"
    local IFS='.'
    read -r a1 a2 a3 <<< "$a"
    read -r b1 b2 b3 <<< "$b"
    a1=${a1:-0}; a2=${a2:-0}; a3=${a3:-0}
    b1=${b1:-0}; b2=${b2:-0}; b3=${b3:-0}
    [ "$a1" -gt "$b1" ] 2>/dev/null && return 0
    [ "$a1" -lt "$b1" ] 2>/dev/null && return 1
    [ "$a2" -gt "$b2" ] 2>/dev/null && return 0
    [ "$a2" -lt "$b2" ] 2>/dev/null && return 1
    [ "$a3" -gt "$b3" ] 2>/dev/null && return 0
    return 1
}
# ===== Extract all data from JSON in a single jq call =====
eval "$(echo "$input" | jq -r '
    def s(v; d): v // d | @sh;
    "model_name=" + s(.model.display_name; "Claude") +
    " size=" + s(.context_window.context_window_size; "200000") +
    " input_tokens=" + s(.context_window.current_usage.input_tokens; "0") +
    " cache_create=" + s(.context_window.current_usage.cache_creation_input_tokens; "0") +
    " cache_read=" + s(.context_window.current_usage.cache_read_input_tokens; "0") +
    " cost_usd=" + s(.cost.total_cost_usd; "") +
    " duration_ms=" + s(.cost.total_duration_ms; "") +
    " lines_added=" + s(.cost.total_lines_added; "") +
    " lines_removed=" + s(.cost.total_lines_removed; "") +
    " cwd=" + s(.cwd; "") +
    " session_id=" + s(.session_id; "") +
    " cc_version=" + s(.version; "") +
    " builtin_five_hour_pct=" + s(.rate_limits.five_hour.used_percentage; "") +
    " builtin_five_hour_reset=" + s(.rate_limits.five_hour.resets_at; "") +
    " builtin_seven_day_pct=" + s(.rate_limits.seven_day.used_percentage; "") +
    " builtin_seven_day_reset=" + s(.rate_limits.seven_day.resets_at; "")
')"

# Shorten model name: "(1M context)" → "1M"
model_name=$(echo "$model_name" | sed 's/ *(\([0-9.]*[kKmM]*\) context)/ \1/')

[ "$size" -eq 0 ] 2>/dev/null && size=200000
current=$(( input_tokens + cache_create + cache_read ))

used_tokens=$(format_tokens $current)
total_tokens=$(format_tokens $size)

if [ "$size" -gt 0 ]; then
    pct_used=$(( current * 100 / size ))
else
    pct_used=0
fi
# Check reasoning effort
settings_path="$claude_config_dir/settings.json"
effort_level="medium"
if [ -n "$CLAUDE_CODE_EFFORT_LEVEL" ]; then
    effort_level="$CLAUDE_CODE_EFFORT_LEVEL"
elif [ -f "$settings_path" ]; then
    effort_val=$(jq -r '.effortLevel // empty' "$settings_path" 2>/dev/null)
    [ -n "$effort_val" ] && effort_level="$effort_val"
fi

# ===== Build context progress bar =====
bar_width=10
filled=$(( pct_used * bar_width / 100 ))
empty=$(( bar_width - filled ))
bar_color=$(usage_color "$pct_used")
ctx_bar="${bar_color}"
for ((i=0; i<filled; i++)); do ctx_bar+="█"; done
for ((i=0; i<empty; i++)); do ctx_bar+="░"; done
ctx_bar+="${reset}"

# ===== Format session duration =====
duration_str=""
if [ -n "$duration_ms" ] && [ "$duration_ms" != "null" ]; then
    total_sec=$(( ${duration_ms%.*} / 1000 ))
    if [ "$total_sec" -ge 3600 ]; then
        dur_h=$(( total_sec / 3600 ))
        dur_m=$(( (total_sec % 3600) / 60 ))
        duration_str="${dur_h}h${dur_m}m"
    elif [ "$total_sec" -ge 60 ]; then
        dur_m=$(( total_sec / 60 ))
        duration_str="${dur_m}m"
    else
        duration_str="${total_sec}s"
    fi
fi

# ===== Extract git info =====
display_dir=""
git_branch=""
git_changes=""
if [ -n "$cwd" ]; then
    display_dir="${cwd##*/}"
    git_branch=$(git -C "${cwd}" rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [ -n "$git_branch" ]; then
        # Staged changes
        staged=$(git -C "${cwd}" diff --cached --numstat 2>/dev/null | awk '{a+=$1; d+=$2} END {if (a+d>0) printf "+%d -%d", a, d}')
        # Unstaged changes
        unstaged=$(git -C "${cwd}" diff --numstat 2>/dev/null | awk '{a+=$1; d+=$2} END {if (a+d>0) printf "+%d -%d", a, d}')
        # Untracked file count
        untracked=$(git -C "${cwd}" ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')

        parts=""
        [ -n "$staged" ] && parts+="${green}●${reset}${staged}"
        [ -n "$unstaged" ] && { [ -n "$parts" ] && parts+=" "; parts+="${orange}●${reset}${unstaged}"; }
        [ "$untracked" -gt 0 ] 2>/dev/null && { [ -n "$parts" ] && parts+=" "; parts+="${red}?${untracked}${reset}"; }
        git_changes="$parts"
    fi
fi

# ===== Build line 1: model | bar used/total (%) | effort | 5h | 7d | extra =====
out=""
out+="${blue}${model_name}${reset}"
bar_color_code=$(usage_color $pct_used)
out+=" ${dim}|${reset} ${ctx_bar} ${bar_color_code}${used_tokens}/${total_tokens}${reset} ${dim}(${reset}${bar_color_code}${pct_used}%${reset}${dim})${reset}"
out+=" ${dim}|${reset} "
out+="effort: "
case "$effort_level" in
    low)    out+="${dim}${effort_level}${reset}" ;;
    medium) out+="${orange}med${reset}" ;;
    max)    out+="${red}${effort_level}${reset}" ;;
    *)      out+="${green}${effort_level}${reset}" ;;
esac

# ===== Cross-platform OAuth token resolution (from statusline.sh) =====
# Tries credential sources in order: env var → macOS Keychain → Linux creds file → GNOME Keyring
get_oauth_token() {
    local token=""

    # 1. Explicit env var override
    if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
        echo "$CLAUDE_CODE_OAUTH_TOKEN"
        return 0
    fi

    # 2. macOS Keychain (Claude Code appends a SHA256 hash of CLAUDE_CONFIG_DIR to the service name)
    if command -v security >/dev/null 2>&1; then
        local keychain_svc="Claude Code-credentials"
        if [ -n "$CLAUDE_CONFIG_DIR" ]; then
            local dir_hash
            dir_hash=$(echo -n "$CLAUDE_CONFIG_DIR" | shasum -a 256 | cut -c1-8)
            keychain_svc="Claude Code-credentials-${dir_hash}"
        fi
        local blob
        blob=$(security find-generic-password -s "$keychain_svc" -w 2>/dev/null)
        if [ -n "$blob" ]; then
            token=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
            if [ -n "$token" ] && [ "$token" != "null" ]; then
                echo "$token"
                return 0
            fi
        fi
    fi

    # 3. Linux credentials file
    local creds_file="${claude_config_dir}/.credentials.json"
    if [ -f "$creds_file" ]; then
        token=$(jq -r '.claudeAiOauth.accessToken // empty' "$creds_file" 2>/dev/null)
        if [ -n "$token" ] && [ "$token" != "null" ]; then
            echo "$token"
            return 0
        fi
    fi

    # 4. GNOME Keyring via secret-tool
    if command -v secret-tool >/dev/null 2>&1; then
        local blob
        blob=$(timeout 2 secret-tool lookup service "Claude Code-credentials" 2>/dev/null)
        if [ -n "$blob" ]; then
            token=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
            if [ -n "$token" ] && [ "$token" != "null" ]; then
                echo "$token"
                return 0
            fi
        fi
    fi

    echo ""
}

# ===== Usage limits =====
use_builtin=false
if [ -n "$builtin_five_hour_pct" ] || [ -n "$builtin_seven_day_pct" ]; then
    use_builtin=true
fi

# Fall back to cached API call only when Claude Code didn't supply rate_limits data
claude_config_dir_hash=$(echo -n "$claude_config_dir" | shasum -a 256 2>/dev/null || echo -n "$claude_config_dir" | sha256sum 2>/dev/null)
claude_config_dir_hash=$(echo "$claude_config_dir_hash" | cut -c1-8)
cache_file="${claude_config_dir}/statusline-cache/statusline-usage-cache-${claude_config_dir_hash}.json"
cache_max_age=60  # seconds between API calls
mkdir -p ${claude_config_dir}/statusline-cache

needs_refresh=true
usage_data=""

if ! $use_builtin; then
    # Check cache — shared across all Claude Code instances to avoid rate limits
    if [ -f "$cache_file" ] && [ -s "$cache_file" ]; then
        cache_mtime=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null)
        now=$(date +%s)
        cache_age=$(( now - cache_mtime ))
        if [ "$cache_age" -lt "$cache_max_age" ]; then
            needs_refresh=false
        fi
        usage_data=$(cat "$cache_file" 2>/dev/null)
    fi

    # Fetch fresh data if cache is stale
    if $needs_refresh; then
        touch "$cache_file"  # stampede lock: prevent parallel panes from fetching simultaneously
        token=$(get_oauth_token)
        if [ -n "$token" ] && [ "$token" != "null" ]; then
            response=$(curl -s --max-time 10 \
                -H "Accept: application/json" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer $token" \
                -H "anthropic-beta: oauth-2025-04-20" \
                -H "User-Agent: claude-code/2.1.34" \
                "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
            # Only cache valid usage responses (not error/rate-limit JSON)
            if [ -n "$response" ] && echo "$response" | jq -e '.five_hour' >/dev/null 2>&1; then
                usage_data="$response"
                echo "$response" > "$cache_file"
            fi
        fi
    fi
fi

# Cross-platform ISO to epoch conversion
# Converts ISO 8601 timestamp (e.g. "2025-06-15T12:30:00Z" or "2025-06-15T12:30:00.123+00:00") to epoch seconds.
# Properly handles UTC timestamps and converts to local time.
iso_to_epoch() {
    local iso_str="$1"

    # Try GNU date first (Linux) — handles ISO 8601 format automatically
    local epoch
    epoch=$(date -d "${iso_str}" +%s 2>/dev/null)
    if [ -n "$epoch" ]; then
        echo "$epoch"
        return 0
    fi

    # BSD date (macOS) - handle various ISO 8601 formats
    local stripped="${iso_str%%.*}"          # Remove fractional seconds (.123456)
    stripped="${stripped%%Z}"                 # Remove trailing Z
    stripped="${stripped%%+*}"               # Remove timezone offset (+00:00)
    stripped="${stripped%%-[0-9][0-9]:[0-9][0-9]}"  # Remove negative timezone offset

    # Check if timestamp is UTC (has Z or +00:00 or -00:00)
    if [[ "$iso_str" == *"Z"* ]] || [[ "$iso_str" == *"+00:00"* ]] || [[ "$iso_str" == *"-00:00"* ]]; then
        # For UTC timestamps, parse with timezone set to UTC
        epoch=$(env TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
    else
        epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
    fi

    if [ -n "$epoch" ]; then
        echo "$epoch"
        return 0
    fi

    return 1
}

# Format ISO reset time to compact local time
# Usage: format_reset_time <iso_string> <style: time|datetime|date>
format_reset_time() {
    local iso_str="$1"
    local style="$2"
    { [ -z "$iso_str" ] || [ "$iso_str" = "null" ]; } && return

    # Parse ISO datetime and convert to local time (cross-platform)
    local epoch
    epoch=$(iso_to_epoch "$iso_str")
    [ -z "$epoch" ] && return

    # Format based on style
    # Try GNU date first (Linux), then BSD date (macOS)
    # Previous implementation piped BSD date through sed/tr, which always returned
    # exit code 0 from the last pipe stage, preventing the GNU date fallback from
    # ever executing on Linux.
    local formatted=""
    case "$style" in
        time)
            formatted=$(date -d "@$epoch" +"%H:%M" 2>/dev/null) || \
            formatted=$(date -j -r "$epoch" +"%H:%M" 2>/dev/null)
            ;;
        datetime)
            formatted=$(date -d "@$epoch" +"%b %-d, %H:%M" 2>/dev/null) || \
            formatted=$(date -j -r "$epoch" +"%b %-d, %H:%M" 2>/dev/null)
            ;;
        *)
            formatted=$(date -d "@$epoch" +"%b %-d" 2>/dev/null) || \
            formatted=$(date -j -r "$epoch" +"%b %-d" 2>/dev/null)
            ;;
    esac
    [ -n "$formatted" ] && echo "$formatted"
}

sep=" ${dim}|${reset} "

if $use_builtin; then
    # ---- Use rate_limits data provided directly by Claude Code in JSON input ----
    # resets_at values are Unix epoch integers in this source
    if [ -n "$builtin_five_hour_pct" ]; then
        five_hour_pct=$(printf "%.0f" "$builtin_five_hour_pct")
        five_hour_color=$(usage_color "$five_hour_pct")
        out+="${sep}${white}5h${reset} ${five_hour_color}${five_hour_pct}%${reset}"
        if [ -n "$builtin_five_hour_reset" ] && [ "$builtin_five_hour_reset" != "null" ]; then
            five_hour_reset=$(date -j -r "$builtin_five_hour_reset" +"%H:%M" 2>/dev/null || date -d "@$builtin_five_hour_reset" +"%H:%M" 2>/dev/null)
            [ -n "$five_hour_reset" ] && out+=" ${dim}@${five_hour_reset}${reset}"
        fi
    fi

    if [ -n "$builtin_seven_day_pct" ]; then
        seven_day_pct=$(printf "%.0f" "$builtin_seven_day_pct")
        seven_day_color=$(usage_color "$seven_day_pct")
        out+="${sep}${white}7d${reset} ${seven_day_color}${seven_day_pct}%${reset}"
        if [ -n "$builtin_seven_day_reset" ] && [ "$builtin_seven_day_reset" != "null" ]; then
            seven_day_reset=$(date -j -r "$builtin_seven_day_reset" +"%b %-d, %H:%M" 2>/dev/null || date -d "@$builtin_seven_day_reset" +"%b %-d, %H:%M" 2>/dev/null)
            [ -n "$seven_day_reset" ] && out+=" ${dim}@${seven_day_reset}${reset}"
        fi
    fi
elif [ -n "$usage_data" ] && echo "$usage_data" | jq -e '.five_hour' >/dev/null 2>&1; then
    # ---- Fall back: API-fetched usage data ----
    # ---- 5-hour (current) ----
    five_hour_pct=$(echo "$usage_data" | jq -r '.five_hour.utilization // 0' | awk '{printf "%.0f", $1}')
    five_hour_reset_iso=$(echo "$usage_data" | jq -r '.five_hour.resets_at // empty')
    five_hour_reset=$(format_reset_time "$five_hour_reset_iso" "time")
    five_hour_color=$(usage_color "$five_hour_pct")

    out+="${sep}${white}5h${reset} ${five_hour_color}${five_hour_pct}%${reset}"
    [ -n "$five_hour_reset" ] && out+=" ${dim}@${five_hour_reset}${reset}"

    # ---- 7-day (weekly) ----
    seven_day_pct=$(echo "$usage_data" | jq -r '.seven_day.utilization // 0' | awk '{printf "%.0f", $1}')
    seven_day_reset_iso=$(echo "$usage_data" | jq -r '.seven_day.resets_at // empty')
    seven_day_reset=$(format_reset_time "$seven_day_reset_iso" "datetime")
    seven_day_color=$(usage_color "$seven_day_pct")

    out+="${sep}${white}7d${reset} ${seven_day_color}${seven_day_pct}%${reset}"
    [ -n "$seven_day_reset" ] && out+=" ${dim}@${seven_day_reset}${reset}"

    # ---- Extra usage ----
    extra_enabled=$(echo "$usage_data" | jq -r '.extra_usage.is_enabled // false')
    if [ "$extra_enabled" = "true" ]; then
        extra_pct=$(echo "$usage_data" | jq -r '.extra_usage.utilization // 0' | awk '{printf "%.0f", $1}')
        extra_used=$(echo "$usage_data" | jq -r '.extra_usage.used_credits // 0' | LC_NUMERIC=C awk '{printf "%.2f", $1/100}')
        extra_limit=$(echo "$usage_data" | jq -r '.extra_usage.monthly_limit // 0' | LC_NUMERIC=C awk '{printf "%.2f", $1/100}')
        # Validate: if values are empty or contain unexpanded variables, show simple "enabled" label
        if [ -n "$extra_used" ] && [ -n "$extra_limit" ] && [[ "$extra_used" != *'$'* ]] && [[ "$extra_limit" != *'$'* ]]; then
            extra_color=$(usage_color "$extra_pct")
            out+="${sep}${white}extra${reset} ${extra_color}\$${extra_used}/\$${extra_limit}${reset}"
        else
            out+="${sep}${white}extra${reset} ${green}enabled${reset}"
        fi
    fi
else
    # No valid usage data — show placeholders
    out+="${sep}${white}5h${reset} ${dim}-${reset}"
    out+="${sep}${white}7d${reset} ${dim}-${reset}"
fi

# ===== Session duration =====
if [ -n "$duration_str" ]; then
    out+="${sep}${dim}${duration_str}${reset}"
fi

# ===== Cost (session + daily + weekly tracker) =====
cost_cache_dir="${claude_config_dir}/statusline-cache"
cost_tracker="${cost_cache_dir}/statusline-cost-$(date +%Y-%m-%d).tsv"
if [ -n "$cost_usd" ] && [ "$cost_usd" != "null" ]; then
    formatted_cost=$(LC_NUMERIC=C awk "BEGIN {printf \"%.2f\", $cost_usd}")
    cost_cents=$(LC_NUMERIC=C awk "BEGIN {printf \"%.0f\", $cost_usd * 100}")
    if [ "$cost_cents" -ge 1000 ]; then cost_color="$red"
    elif [ "$cost_cents" -ge 500 ]; then cost_color="$orange"
    elif [ "$cost_cents" -ge 200 ]; then cost_color="$yellow"
    else cost_color="$green"
    fi

    # Track cost per session_id in daily file
    if [ -n "$session_id" ] && [ "$session_id" != "null" ]; then
        if [ -f "$cost_tracker" ]; then
            grep -v "^${session_id}	" "$cost_tracker" > "${cost_tracker}.tmp" 2>/dev/null || true
            mv "${cost_tracker}.tmp" "$cost_tracker"
        fi
        echo "${session_id}	${cost_usd}" >> "$cost_tracker"

        # Sum today
        daily_cost=$(LC_NUMERIC=C awk -F'\t' '{s+=$2} END {printf "%.2f", s}' "$cost_tracker" 2>/dev/null)

        # Sum from 7-day reset window start date to today
        week_start_date=""
        if [ -n "$builtin_seven_day_reset" ] && [ "$builtin_seven_day_reset" != "null" ]; then
            week_start_epoch=$(( builtin_seven_day_reset - 7 * 86400 ))
            week_start_date=$(date -d "@$week_start_epoch" +%Y-%m-%d 2>/dev/null || date -j -r "$week_start_epoch" +%Y-%m-%d 2>/dev/null)
        fi
        weekly_cost="0.00"
        for i in 0 1 2 3 4 5 6 7 8 9; do
            day_date=$(date -d "-${i} days" +%Y-%m-%d 2>/dev/null || date -v-${i}d +%Y-%m-%d 2>/dev/null)
            # Stop if this day is before the window start date
            if [ -n "$week_start_date" ]; then
                [[ "$day_date" < "$week_start_date" ]] && break
            elif [ "$i" -ge 7 ]; then
                break
            fi
            day_file="${cost_cache_dir}/statusline-cost-${day_date}.tsv"
            [ -f "$day_file" ] && weekly_cost=$(LC_NUMERIC=C awk -F'\t' -v w="$weekly_cost" '{s+=$2} END {printf "%.2f", s+w}' "$day_file")
        done

        daily_cents=$(LC_NUMERIC=C awk "BEGIN {printf \"%.0f\", $daily_cost * 100}")
        weekly_cents=$(LC_NUMERIC=C awk "BEGIN {printf \"%.0f\", $weekly_cost * 100}")

        if [ "$daily_cents" -ge 1000 ]; then daily_color="$red"
        elif [ "$daily_cents" -ge 500 ]; then daily_color="$orange"
        elif [ "$daily_cents" -ge 200 ]; then daily_color="$yellow"
        else daily_color="$green"
        fi
        if [ "$weekly_cents" -ge 5000 ]; then weekly_color="$red"
        elif [ "$weekly_cents" -ge 2000 ]; then weekly_color="$orange"
        elif [ "$weekly_cents" -ge 1000 ]; then weekly_color="$yellow"
        else weekly_color="$green"
        fi

        out+="${sep}${cost_color}\$${formatted_cost}${reset} ${dim}(${reset}${daily_color}\$${daily_cost}${reset}${dim}/d${reset} ${weekly_color}\$${weekly_cost}${reset}${dim}/w)${reset}"
    else
        out+="${sep}${cost_color}\$${formatted_cost}${reset}"
    fi
fi

# ===== Build line 2: CWD@Branch | git changes | session lines =====
line2=""
if [ -n "$display_dir" ]; then
    line2+="${cyan}${display_dir}${reset}"
    if [ -n "$git_branch" ]; then
        line2+="${dim}@${reset}${green}${git_branch}${reset}"
    fi
    if [ -n "$git_changes" ]; then
        line2+="${sep}${git_changes}"
    fi
fi

# Session lines added/removed
if [ -n "$lines_added" ] && [ "$lines_added" != "null" ] && [ "$lines_added" != "0" ] || \
   [ -n "$lines_removed" ] && [ "$lines_removed" != "null" ] && [ "$lines_removed" != "0" ]; then
    line2+="${sep}${dim}session${reset}"
    [ -n "$lines_added" ] && [ "$lines_added" != "null" ] && [ "$lines_added" != "0" ] && line2+=" ${green}+${lines_added}${reset}"
    [ -n "$lines_removed" ] && [ "$lines_removed" != "null" ] && [ "$lines_removed" != "0" ] && line2+=" ${red}-${lines_removed}${reset}"
fi

# ===== Claude Code update check (cached, 24h TTL) =====
if [ -n "$cc_version" ] && [ "$cc_version" != "null" ]; then
    cc_version_cache="${claude_config_dir}/statusline-cache/statusline-cc-version-cache.txt"
    cc_cache_max_age=86400

    cc_latest=""
    if [ -f "$cc_version_cache" ] && [ -s "$cc_version_cache" ]; then
        cc_mtime=$(stat -c %Y "$cc_version_cache" 2>/dev/null || stat -f %m "$cc_version_cache" 2>/dev/null)
        cc_now=$(date +%s)
        cc_age=$(( cc_now - cc_mtime ))
        if [ "$cc_age" -lt "$cc_cache_max_age" ]; then
            cc_latest=$(cat "$cc_version_cache" 2>/dev/null)
        fi
    fi

    if [ -z "$cc_latest" ]; then
        touch "$cc_version_cache" 2>/dev/null
        cc_latest=$(npm view @anthropic-ai/claude-code version 2>/dev/null)
        [ -n "$cc_latest" ] && echo "$cc_latest" > "$cc_version_cache"
    fi

    if [ -n "$cc_latest" ] && version_gt "$cc_latest" "$cc_version"; then
        line2+="${sep}${yellow}CC update: ${cc_version} → ${cc_latest}${reset}"
    fi
fi

# ===== Caveman mode badge =====
caveman_flag="${claude_config_dir}/.caveman-active"
caveman_badge=""
if [ ! -L "$caveman_flag" ] && [ -f "$caveman_flag" ]; then
    caveman_mode=$(head -c 64 "$caveman_flag" 2>/dev/null | tr -d '\n\r' | tr '[:upper:]' '[:lower:]')
    caveman_mode=$(printf '%s' "$caveman_mode" | tr -cd 'a-z0-9-')
    case "$caveman_mode" in
        off|lite|full|ultra|wenyan-lite|wenyan|wenyan-full|wenyan-ultra|commit|review|compress)
            if [ "$caveman_mode" = "off" ]; then
                caveman_badge=""
            elif [ -z "$caveman_mode" ] || [ "$caveman_mode" = "full" ]; then
                caveman_badge="\033[38;5;172m[CAVEMAN]\033[0m"
            else
                caveman_suffix=$(printf '%s' "$caveman_mode" | tr '[:lower:]' '[:upper:]')
                caveman_badge="\033[38;5;172m[CAVEMAN:${caveman_suffix}]\033[0m"
            fi
            ;;
    esac
fi

# Output
output="$out"
[ -n "$caveman_badge" ] && output+=" ${dim}|${reset} ${caveman_badge}"
[ -n "$line2" ] && output+="\n${line2}"
printf "%b" "$output"

exit 0
