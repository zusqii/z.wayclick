#!/usr/bin/env bash

set -euo pipefail
shopt -s extglob

declare -r CONFIG_FILE="${HOME}/.scripts/wayclick/wayclick.sh"
declare -r APP_TITLE="WayClick Configurator"
declare -r APP_VERSION="v1.0.0"

# Dimensions & Layout
declare -ri MAX_DISPLAY_ROWS=14
declare -ri BOX_INNER_WIDTH=76
declare -ri ADJUST_THRESHOLD=38
declare -ri ITEM_PADDING=32

declare -ri HEADER_ROWS=4
declare -ri TAB_ROW=3
declare -ri ITEM_START_ROW=$(( HEADER_ROWS + 1 ))

declare -ra TABS=("Audio" "Devices" "Advanced")

discover_audio_packs() {
    local config_dir="${HOME}/.config/wayclick"
    local -a packs=()
    local dir_name

    if [[ -d "$config_dir" ]]; then
        while IFS= read -r dir_name; do
            [[ -n "$dir_name" ]] && packs+=("$dir_name")
        done < <(find "$config_dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort)
    fi

    if (( ${#packs[@]} == 0 )); then
        REPLY="audio_pack_1"
    else
        local IFS=','
        REPLY="${packs[*]}"
    fi
}

register_items() {
    # Discover audio packs before registration
    local audio_pack_options
    discover_audio_packs
    audio_pack_options="$REPLY"

    # Tab 0: Audio
    register 0 "Audio Pack"     "AUDIO_PACK|cycle||${audio_pack_options}||"           "audio_pack_1"
    register 0 "Buffer Size"    'AUDIO_BUFFER_SIZE|cycle||128,256,512||'              "128"
    register 0 "Sample Rate"    'AUDIO_SAMPLE_RATE|cycle||44100,48000||'              "48000"
    register 0 "Mix Channels"   'AUDIO_MIX_CHANNELS|cycle||8,16,32,64||'             "16"

    # Tab 1: Devices
    register 1 "Trackpad Sounds"      'ENABLE_TRACKPAD_SOUNDS|bool||||'              "false"
    register 1 "Auto-Detect Touchpads" 'AUTO_DETECT_TRACKPADS|bool||||'              "true"
    register 1 "Hotplug Poll (sec)"   'HOTPLUG_POLL_SECONDS|float||0.5|5.0|0.5'     "1.0"

    # Tab 2: Advanced
    register 2 "Debug Mode"     'DEBUG_MODE|bool||||'                                "false"
}

post_write_action() {
    :
}

declare _h_line_buf
printf -v _h_line_buf '%*s' "$BOX_INNER_WIDTH" ''
declare -r H_LINE="${_h_line_buf// /─}"
unset _h_line_buf

declare -r C_RESET=$'\033[0m'
declare -r C_CYAN=$'\033[1;36m'
declare -r C_GREEN=$'\033[1;32m'
declare -r C_MAGENTA=$'\033[1;35m'
declare -r C_RED=$'\033[1;31m'
declare -r C_YELLOW=$'\033[1;33m'
declare -r C_WHITE=$'\033[1;37m'
declare -r C_GREY=$'\033[1;30m'
declare -r C_INVERSE=$'\033[7m'
declare -r CLR_EOL=$'\033[K'
declare -r CLR_EOS=$'\033[J'
declare -r CLR_SCREEN=$'\033[2J'
declare -r CURSOR_HOME=$'\033[H'
declare -r CURSOR_HIDE=$'\033[?25l'
declare -r CURSOR_SHOW=$'\033[?25h'
declare -r MOUSE_ON=$'\033[?1000h\033[?1002h\033[?1006h'
declare -r MOUSE_OFF=$'\033[?1000l\033[?1002l\033[?1006l'

# Increased timeout for SSH/remote reliability
declare -r ESC_READ_TIMEOUT=0.10
declare -r UNSET_MARKER='«unset»'

declare -i SELECTED_ROW=0
declare -i CURRENT_TAB=0
declare -i SCROLL_OFFSET=0
declare -ri TAB_COUNT=${#TABS[@]}
declare -a TAB_ZONES=()
declare -i TAB_SCROLL_START=0
declare ORIGINAL_STTY=""

declare -i CURRENT_VIEW=0      # 0=Main List, 1=Detail/Sub-Page
declare CURRENT_MENU_ID=""     # ID of the currently open menu
declare -i PARENT_ROW=0        # Saved row to return to
declare -i PARENT_SCROLL=0     # Saved scroll to return to

declare _TMPFILE=""

declare LEFT_ARROW_ZONE=""
declare RIGHT_ARROW_ZONE=""

declare -A ITEM_MAP=()
declare -A VALUE_CACHE=()
declare -A CONFIG_CACHE=()
declare -A DEFAULTS=()

for (( _ti = 0; _ti < TAB_COUNT; _ti++ )); do
    declare -ga "TAB_ITEMS_${_ti}=()"
done
unset _ti

log_err() {
    printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$1" >&2
}

cleanup() {
    printf '%s%s%s' "$MOUSE_OFF" "$CURSOR_SHOW" "$C_RESET" 2>/dev/null || :
    if [[ -n "${ORIGINAL_STTY:-}" ]]; then
        stty "$ORIGINAL_STTY" 2>/dev/null || :
    fi
    # Secure temp file cleanup
    if [[ -n "${_TMPFILE:-}" && -f "$_TMPFILE" ]]; then
        rm -f "$_TMPFILE" 2>/dev/null || :
    fi
    printf '\n' 2>/dev/null || :
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

strip_ansi() {
    local v="$1"
    v="${v//$'\033'\[*([0-9;:?<=>])@([@A-Z\[\\\]^_\`a-z\{|\}~])/}"
    REPLY="$v"
}

register() {
    local -i tab_idx=$1
    local label="$2" config="$3" default_val="${4:-}"
    local key type block min max step
    IFS='|' read -r key type block min max step <<< "$config"

    case "$type" in
        bool|int|float|cycle|menu) ;;
        *) log_err "Invalid type for '${label}': ${type}"; exit 1 ;;
    esac

    ITEM_MAP["${tab_idx}::${label}"]="$config"
    if [[ -n "$default_val" ]]; then DEFAULTS["${tab_idx}::${label}"]="$default_val"; fi
    local -n _reg_tab_ref="TAB_ITEMS_${tab_idx}"
    _reg_tab_ref+=("$label")

    if [[ "$type" == "menu" ]]; then
        if ! declare -p "SUBMENU_ITEMS_${key}" &>/dev/null; then
            declare -ga "SUBMENU_ITEMS_${key}=()"
        fi
    fi
}

register_child() {
    local parent_id="$1"
    local label="$2" config="$3" default_val="${4:-}"

    if [[ ! "$parent_id" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        log_err "Register Error: Menu ID '${parent_id}' contains invalid characters."
        exit 1
    fi

    if ! declare -p "SUBMENU_ITEMS_${parent_id}" &>/dev/null; then
        declare -ga "SUBMENU_ITEMS_${parent_id}=()"
    fi

    ITEM_MAP["${parent_id}::${label}"]="$config"
    if [[ -n "$default_val" ]]; then DEFAULTS["${parent_id}::${label}"]="$default_val"; fi

    local -n _child_ref="SUBMENU_ITEMS_${parent_id}"
    _child_ref+=("$label")
}

# Key differences from the template's Hyprland parser:
#   1. No brace/block depth tracking (flat file, all items are global)
#   2. Heredoc-aware: detects `<< 'DELIM'` / `<< DELIM` and skips until DELIM
#   3. Strips `readonly ` prefix from variable names
#   4. Strips surrounding double quotes from values
#   5. Output format is identical: `key|=value` (empty block field)
# =============================================================================
populate_config_cache() {
    CONFIG_CACHE=()
    local key_part value_part key_name

    while IFS='=' read -r key_part value_part || [[ -n "${key_part:-}" ]]; do
        if [[ -z "${key_part:-}" ]]; then continue; fi
        CONFIG_CACHE["$key_part"]="$value_part"
        key_name="${key_part%%|*}"
        if [[ -z "${CONFIG_CACHE["${key_name}|"]:-}" ]]; then
            CONFIG_CACHE["${key_name}|"]="$value_part"
        fi
    done < <(LC_ALL=C awk '
        BEGIN {
            in_heredoc = 0
            heredoc_delim = ""
        }

        # --- Heredoc tracking ---
        # Detect heredoc start: matches << WORD or << '"'"'WORD'"'"' patterns
        # This prevents the parser from seeing Python assignments inside the
        # embedded runner script as bash variable declarations.
        in_heredoc && $0 == heredoc_delim {
            in_heredoc = 0
            heredoc_delim = ""
            next
        }
        in_heredoc { next }

        /<<[[:space:]]*'"'"'?[A-Za-z_][A-Za-z_0-9]*'"'"'?[[:space:]]*$/ {
            line = $0
            # Extract delimiter: strip everything up to and including <<
            sub(/.*<<[[:space:]]*/, "", line)
            # Strip quotes around delimiter
            gsub(/'"'"'/, "", line)
            # Strip trailing whitespace
            sub(/[[:space:]]+$/, "", line)
            if (line != "") {
                in_heredoc = 1
                heredoc_delim = line
            }
        }
        in_heredoc { next }

        # --- Skip comments ---
        /^[[:space:]]*#/ { next }

        # --- Parse variable declarations ---
        /=/ {
            line = $0

            # Strip inline comments (outside quotes — safe for our use case
            # since all WayClick config values are simple quoted scalars)
            clean = line
            sub(/[[:space:]]+#.*$/, "", clean)

            eq_pos = index(clean, "=")
            if (eq_pos > 0) {
                key = substr(clean, 1, eq_pos - 1)
                val = substr(clean, eq_pos + 1)

                # Strip leading/trailing whitespace from key
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)

                # Strip "readonly " prefix (with optional whitespace variations)
                sub(/^readonly[[:space:]]+/, "", key)

                # Strip "declare " and variants (e.g., declare -r)
                sub(/^declare[[:space:]]+-[a-zA-Z]*[[:space:]]+/, "", key)

                # Strip "export " prefix
                sub(/^export[[:space:]]+/, "", key)

                # Strip leading/trailing whitespace from value
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)

                # Strip surrounding double quotes from value
                if (substr(val, 1, 1) == "\"" && substr(val, length(val), 1) == "\"") {
                    val = substr(val, 2, length(val) - 2)
                }

                # Strip surrounding single quotes from value
                if (substr(val, 1, 1) == "\047" && substr(val, length(val), 1) == "\047") {
                    val = substr(val, 2, length(val) - 2)
                }

                # Only emit if key looks like a valid bash variable name
                if (key ~ /^[A-Za-z_][A-Za-z_0-9]*$/ && key != "") {
                    print key "|=" val
                }
            }
        }
    ' "$CONFIG_FILE")
}

# Key differences from the template's Hyprland writer:
#   1. No block context matching (block parameter always empty)
#   2. Matches `readonly VAR="value"` pattern specifically
#   3. Preserves: leading whitespace, `readonly` prefix, quote style
#   4. Heredoc-aware: will not modify lines inside heredoc blocks
#   5. ENVIRON-based injection prevention: kept from template
#   6. Temp file integrity + symlink preservation: kept from template
# =============================================================================
write_value_to_file() {
    local key="$1" new_val="$2" block="${3:-}"
    local current_val="${CONFIG_CACHE["$key|$block"]:-}"
    if [[ "$current_val" == "$new_val" ]]; then return 0; fi

    # Verify key exists in cache before attempting write
    if [[ -z "${CONFIG_CACHE["$key|"]:-}" ]]; then
        return 1
    fi

    # Create temp file
    if [[ -z "$_TMPFILE" ]]; then
        _TMPFILE=$(mktemp "${CONFIG_FILE}.tmp.XXXXXXXXXX")
    fi

    # ENVIRON-based awk: prevents injection attacks via values
    TARGET_KEY="$key" NEW_VALUE="$new_val" \
    LC_ALL=C awk '
    BEGIN {
        replaced = 0
        target_key = ENVIRON["TARGET_KEY"]
        new_value = ENVIRON["NEW_VALUE"]
        in_heredoc = 0
        heredoc_delim = ""
    }
    {
        line = $0

        # --- Heredoc tracking (safety: never modify inside heredocs) ---
        if (in_heredoc) {
            if ($0 == heredoc_delim) {
                in_heredoc = 0
                heredoc_delim = ""
            }
            print line
            next
        }

        # Detect heredoc start
        if (match(line, /<<[[:space:]]*'"'"'?[A-Za-z_][A-Za-z_0-9]*'"'"'?[[:space:]]*$/)) {
            tmp = line
            sub(/.*<<[[:space:]]*/, "", tmp)
            gsub(/'"'"'/, "", tmp)
            sub(/[[:space:]]+$/, "", tmp)
            if (tmp != "") {
                in_heredoc = 1
                heredoc_delim = tmp
            }
            print line
            next
        }

        # --- Skip comment-only lines ---
        clean = line
        sub(/^[[:space:]]*#.*/, "", clean)
        if (clean == "") {
            print line
            next
        }

        # --- Attempt match on variable declaration ---
        do_replace = 0
        if (line ~ /=/) {
            # Extract key: strip readonly/export prefix, get name before =
            work = line
            # Remove leading whitespace for analysis
            sub(/^[[:space:]]+/, "", work)
            # Remove readonly/export/declare prefix
            sub(/^readonly[[:space:]]+/, "", work)
            sub(/^declare[[:space:]]+-[a-zA-Z]*[[:space:]]+/, "", work)
            sub(/^export[[:space:]]+/, "", work)

            eq = index(work, "=")
            if (eq > 0) {
                k = substr(work, 1, eq - 1)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
                if (k == target_key) {
                    do_replace = 1
                }
            }
        }

        if (do_replace && !replaced) {
            # Preserve everything before the = sign in the ORIGINAL line
            eq_orig = index(line, "=")
            before_eq = substr(line, 1, eq_orig)
            after_eq = substr(line, eq_orig + 1)

            # Determine quote style from original value
            gsub(/^[[:space:]]+/, "", after_eq)

            # Check for inline comment after closing quote
            # Pattern: "value" # comment  OR  "value"  (no comment)
            inline_comment = ""

            if (substr(after_eq, 1, 1) == "\"") {
                # Double-quoted value — find closing quote
                rest = substr(after_eq, 2)
                close_pos = index(rest, "\"")
                if (close_pos > 0) {
                    tail = substr(rest, close_pos + 1)
                    if (match(tail, /[[:space:]]+#.*/)) {
                        inline_comment = substr(tail, RSTART, RLENGTH)
                    }
                }
                print before_eq "\"" new_value "\"" inline_comment
            } else if (substr(after_eq, 1, 1) == "\047") {
                # Single-quoted value — find closing quote
                rest = substr(after_eq, 2)
                close_pos = index(rest, "\047")
                if (close_pos > 0) {
                    tail = substr(rest, close_pos + 1)
                    if (match(tail, /[[:space:]]+#.*/)) {
                        inline_comment = substr(tail, RSTART, RLENGTH)
                    }
                }
                print before_eq "\"" new_value "\"" inline_comment
            } else {
                # Unquoted value
                if (match(after_eq, /[[:space:]]+#.*/)) {
                    inline_comment = substr(after_eq, RSTART, RLENGTH)
                }
                print before_eq "\"" new_value "\"" inline_comment
            }

            replaced = 1
        } else {
            print line
        }
    }
    END { exit (replaced ? 0 : 1) }
    ' "$CONFIG_FILE" > "$_TMPFILE" || {
        rm -f "$_TMPFILE" 2>/dev/null || :
        _TMPFILE=""
        return 1
    }

    # Verify temp file integrity before truncating config (Data Loss Prevention)
    if [[ ! -s "$_TMPFILE" ]]; then
        rm -f "$_TMPFILE" 2>/dev/null || :
        _TMPFILE=""
        return 1
    fi

    # CRITICAL: Use cat > target to preserve symlinks/inodes.
    # Do NOT use mv, as it breaks dotfile symlink chains.
    cat "$_TMPFILE" > "$CONFIG_FILE"
    rm -f "$_TMPFILE"
    _TMPFILE=""

    CONFIG_CACHE["$key|$block"]="$new_val"
    if [[ -z "$block" ]]; then CONFIG_CACHE["$key|"]="$new_val"; fi
    return 0
}

get_active_context() {
    if (( CURRENT_VIEW == 0 )); then
        REPLY_CTX="${CURRENT_TAB}"
        REPLY_REF="TAB_ITEMS_${CURRENT_TAB}"
    else
        REPLY_CTX="${CURRENT_MENU_ID}"
        REPLY_REF="SUBMENU_ITEMS_${CURRENT_MENU_ID}"
    fi
}

load_active_values() {
    local REPLY_REF REPLY_CTX
    get_active_context
    local -n _lav_items_ref="$REPLY_REF"
    local item key type block val

    for item in "${_lav_items_ref[@]}"; do
        IFS='|' read -r key type block _ _ _ <<< "${ITEM_MAP["${REPLY_CTX}::${item}"]}"
        val="${CONFIG_CACHE["$key|$block"]:-}"
        if [[ -z "$val" && -z "$block" ]]; then
            val="${CONFIG_CACHE["$key|"]:-}"
        fi
        if [[ -z "$val" ]]; then
            VALUE_CACHE["${REPLY_CTX}::${item}"]="$UNSET_MARKER"
        else
            VALUE_CACHE["${REPLY_CTX}::${item}"]="$val"
        fi
    done
}

modify_value() {
    local label="$1"
    local -i direction=$2
    local REPLY_REF REPLY_CTX
    get_active_context

    local key type block min max step current new_val
    IFS='|' read -r key type block min max step <<< "${ITEM_MAP["${REPLY_CTX}::${label}"]}"
    current="${VALUE_CACHE["${REPLY_CTX}::${label}"]:-}"

    if [[ "$current" == "$UNSET_MARKER" || -z "$current" ]]; then
        current="${DEFAULTS["${REPLY_CTX}::${label}"]:-}"
        [[ -z "$current" ]] && current="${min:-0}"
    fi

    case "$type" in
        int)
            if [[ ! "$current" =~ ^-?[0-9]+$ ]]; then current="${min:-0}"; fi

            local -i int_val=0
            local _stripped="${current#-}"
            if [[ -n "$_stripped" ]]; then
                int_val=$(( 10#$_stripped ))
            fi
            if [[ "$current" == -* ]]; then
                int_val=$(( -int_val ))
            fi

            local -i int_step=${step:-1}
            int_val=$(( int_val + direction * int_step ))

            # Safe clamping
            if [[ -n "$min" ]]; then
                local -i min_i
                local _min_s="${min#-}"
                min_i=$(( 10#${_min_s:-0} ))
                [[ "$min" == -* ]] && min_i=$(( -min_i ))
                if (( int_val < min_i )); then int_val=$min_i; fi
            fi
            if [[ -n "$max" ]]; then
                local -i max_i
                local _max_s="${max#-}"
                max_i=$(( 10#${_max_s:-0} ))
                [[ "$max" == -* ]] && max_i=$(( -max_i ))
                if (( int_val > max_i )); then int_val=$max_i; fi
            fi
            new_val=$int_val
            ;;
        float)
            if [[ ! "$current" =~ ^-?[0-9]*\.?[0-9]+$ ]]; then current="${min:-0.0}"; fi
            new_val=$(LC_ALL=C awk -v c="$current" -v dir="$direction" -v s="${step:-0.1}" \
                          -v mn="$min" -v mx="$max" 'BEGIN {
                val = c + (dir * s)
                if (mn != "" && val < mn+0) val = mn+0
                if (mx != "" && val > mx+0) val = mx+0
                if (val == 0) val = 0
                str = sprintf("%.6f", val)
                sub(/0+$/, "", str)
                sub(/\.$/, "", str)
                if (str == "-0") str = "0"
                print str
            }')
            ;;
        bool)
            if [[ "$current" == "true" ]]; then new_val="false"; else new_val="true"; fi
            ;;
        cycle)
            local -a opts
            IFS=',' read -r -a opts <<< "$min"
            local -i count=${#opts[@]} idx=0 i
            (( count == 0 )) && return 0
            for (( i = 0; i < count; i++ )); do
                if [[ "${opts[i]}" == "$current" ]]; then idx=$i; break; fi
            done
            idx=$(( (idx + direction + count) % count ))
            new_val="${opts[idx]}"
            ;;
        menu) return 0 ;;
        *) return 0 ;;
    esac

    if write_value_to_file "$key" "$new_val" "$block"; then
        VALUE_CACHE["${REPLY_CTX}::${label}"]="$new_val"
        post_write_action
    fi
}

set_absolute_value() {
    local label="$1" new_val="$2"
    local REPLY_REF REPLY_CTX
    get_active_context
    local key type block
    IFS='|' read -r key type block _ _ _ <<< "${ITEM_MAP["${REPLY_CTX}::${label}"]}"
    if write_value_to_file "$key" "$new_val" "$block"; then
        VALUE_CACHE["${REPLY_CTX}::${label}"]="$new_val"
        return 0
    fi
    return 1
}

reset_defaults() {
    local REPLY_REF REPLY_CTX
    get_active_context
    local -n _rd_items_ref="$REPLY_REF"
    local item def_val
    local -i any_written=0
    for item in "${_rd_items_ref[@]}"; do
        def_val="${DEFAULTS["${REPLY_CTX}::${item}"]:-}"
        if [[ -n "$def_val" ]]; then
            if set_absolute_value "$item" "$def_val"; then
                any_written=1
            fi
        fi
    done
    # SAFETY: Bare (( expr )) returns exit code 1 when expr is 0.
    # Under set -e, this would terminate the script if no defaults were written.
    (( any_written )) && post_write_action || :
    return 0
}

compute_scroll_window() {
    local -i count=$1
    if (( count == 0 )); then
        SELECTED_ROW=0; SCROLL_OFFSET=0
        _vis_start=0; _vis_end=0
        return
    fi

    if (( SELECTED_ROW < 0 )); then SELECTED_ROW=0; fi
    if (( SELECTED_ROW >= count )); then SELECTED_ROW=$(( count - 1 )); fi

    if (( SELECTED_ROW < SCROLL_OFFSET )); then
        SCROLL_OFFSET=$SELECTED_ROW
    elif (( SELECTED_ROW >= SCROLL_OFFSET + MAX_DISPLAY_ROWS )); then
        SCROLL_OFFSET=$(( SELECTED_ROW - MAX_DISPLAY_ROWS + 1 ))
    fi

    local -i max_scroll=$(( count - MAX_DISPLAY_ROWS ))
    if (( max_scroll < 0 )); then max_scroll=0; fi
    if (( SCROLL_OFFSET > max_scroll )); then SCROLL_OFFSET=$max_scroll; fi

    _vis_start=$SCROLL_OFFSET
    _vis_end=$(( SCROLL_OFFSET + MAX_DISPLAY_ROWS ))
    if (( _vis_end > count )); then _vis_end=$count; fi
}

render_scroll_indicator() {
    local -n _rsi_buf=$1
    local position="$2"
    local -i count=$3 boundary=$4

    if [[ "$position" == "above" ]]; then
        if (( SCROLL_OFFSET > 0 )); then
            _rsi_buf+="${C_GREY}    ▲ (more above)${CLR_EOL}${C_RESET}"$'\n'
        else
            _rsi_buf+="${CLR_EOL}"$'\n'
        fi
    else
        if (( count > MAX_DISPLAY_ROWS )); then
            local position_info="[$(( SELECTED_ROW + 1 ))/${count}]"
            if (( boundary < count )); then
                _rsi_buf+="${C_GREY}    ▼ (more below) ${position_info}${CLR_EOL}${C_RESET}"$'\n'
            else
                _rsi_buf+="${C_GREY}                   ${position_info}${CLR_EOL}${C_RESET}"$'\n'
            fi
        else
            _rsi_buf+="${CLR_EOL}"$'\n'
        fi
    fi
}

render_item_list() {
    local -n _ril_buf=$1
    local -n _ril_items=$2
    local _ril_ctx="$3"
    local -i _ril_vs=$4 _ril_ve=$5

    local -i ri
    local item val display type config padded_item

    for (( ri = _ril_vs; ri < _ril_ve; ri++ )); do
        item="${_ril_items[ri]}"
        val="${VALUE_CACHE["${_ril_ctx}::${item}"]:-${UNSET_MARKER}}"
        config="${ITEM_MAP["${_ril_ctx}::${item}"]}"
        IFS='|' read -r _ type _ _ _ _ <<< "$config"

        case "$type" in
            menu) display="${C_YELLOW}[+] Open Menu ...${C_RESET}" ;;
            *)
                case "$val" in
                    true)              display="${C_GREEN}ON${C_RESET}" ;;
                    false)             display="${C_RED}OFF${C_RESET}" ;;
                    "$UNSET_MARKER")   display="${C_YELLOW}⚠ UNSET${C_RESET}" ;;
                    *)                 display="${C_WHITE}${val}${C_RESET}" ;;
                esac
                ;;
        esac

        # Ellipsis for truncated items
        local max_len=$(( ITEM_PADDING - 1 ))
        if (( ${#item} > ITEM_PADDING )); then
            printf -v padded_item "%-${max_len}s…" "${item:0:max_len}"
        else
            printf -v padded_item "%-${ITEM_PADDING}s" "$item"
        fi

        if (( ri == SELECTED_ROW )); then
            _ril_buf+="${C_CYAN} ➤ ${C_INVERSE}${padded_item}${C_RESET} : ${display}${CLR_EOL}"$'\n'
        else
            _ril_buf+="    ${padded_item} : ${display}${CLR_EOL}"$'\n'
        fi
    done

    # Fill empty rows
    local -i rows_rendered=$(( _ril_ve - _ril_vs ))
    for (( ri = rows_rendered; ri < MAX_DISPLAY_ROWS; ri++ )); do
        _ril_buf+="${CLR_EOL}"$'\n'
    done
}

draw_main_view() {
    local buf="" pad_buf=""
    local -i i current_col=3 zone_start len count pad_needed
    local -i left_pad right_pad vis_len
    local -i _vis_start _vis_end

    buf+="${CURSOR_HOME}"
    buf+="${C_MAGENTA}┌${H_LINE}┐${C_RESET}${CLR_EOL}"$'\n'

    strip_ansi "$APP_TITLE"; local -i t_len=${#REPLY}
    strip_ansi "$APP_VERSION"; local -i v_len=${#REPLY}
    vis_len=$(( t_len + v_len + 1 ))
    left_pad=$(( (BOX_INNER_WIDTH - vis_len) / 2 ))
    right_pad=$(( BOX_INNER_WIDTH - vis_len - left_pad ))

    printf -v pad_buf '%*s' "$left_pad" ''
    buf+="${C_MAGENTA}│${pad_buf}${C_WHITE}${APP_TITLE} ${C_CYAN}${APP_VERSION}${C_MAGENTA}"
    printf -v pad_buf '%*s' "$right_pad" ''
    buf+="${pad_buf}│${C_RESET}${CLR_EOL}"$'\n'

    # --- Scrollable Tab Rendering (Sliding Window) ---
    if (( TAB_SCROLL_START > CURRENT_TAB )); then
        TAB_SCROLL_START=$CURRENT_TAB
    fi

    local tab_line
    local -i max_tab_width=$(( BOX_INNER_WIDTH - 6 ))

    LEFT_ARROW_ZONE=""
    RIGHT_ARROW_ZONE=""

    while true; do
        tab_line="${C_MAGENTA}│ "
        current_col=3
        TAB_ZONES=()
        local -i used_len=0

        # Left Arrow
        if (( TAB_SCROLL_START > 0 )); then
            tab_line+="${C_YELLOW}«${C_RESET} "
            LEFT_ARROW_ZONE="$current_col:$((current_col+1))"
            used_len=$(( used_len + 2 ))
            current_col=$(( current_col + 2 ))
        else
            tab_line+="  "
            used_len=$(( used_len + 2 ))
            current_col=$(( current_col + 2 ))
        fi

        for (( i = TAB_SCROLL_START; i < TAB_COUNT; i++ )); do
            local name="${TABS[i]}"
            local t_len=${#name}
            local chunk_len=$(( t_len + 4 ))

            local reserve=0
            if (( i < TAB_COUNT - 1 )); then reserve=2; fi

            if (( used_len + chunk_len + reserve > max_tab_width )); then
                if (( i <= CURRENT_TAB )); then
                    TAB_SCROLL_START=$(( TAB_SCROLL_START + 1 ))
                    continue 2
                fi
                tab_line+="${C_YELLOW}» ${C_RESET}"
                RIGHT_ARROW_ZONE="$current_col:$((current_col+1))"
                used_len=$(( used_len + 2 ))
                break
            fi

            zone_start=$current_col
            if (( i == CURRENT_TAB )); then
                tab_line+="${C_CYAN}${C_INVERSE} ${name} ${C_RESET}${C_MAGENTA}│ "
            else
                tab_line+="${C_GREY} ${name} ${C_MAGENTA}│ "
            fi

            TAB_ZONES+=("${zone_start}:$(( zone_start + t_len + 1 ))")
            used_len=$(( used_len + chunk_len ))
            current_col=$(( current_col + chunk_len ))
        done

        local pad=$(( BOX_INNER_WIDTH - used_len - 1 ))
        if (( pad > 0 )); then
            printf -v pad_buf '%*s' "$pad" ''
            tab_line+="$pad_buf"
        fi

        tab_line+="${C_MAGENTA}│${C_RESET}"
        break
    done

    buf+="${tab_line}${CLR_EOL}"$'\n'
    buf+="${C_MAGENTA}└${H_LINE}┘${C_RESET}${CLR_EOL}"$'\n'

    # Items
    local items_var="TAB_ITEMS_${CURRENT_TAB}"
    local -n _draw_items_ref="$items_var"
    count=${#_draw_items_ref[@]}

    compute_scroll_window "$count"
    render_scroll_indicator buf "above" "$count" "$_vis_start"
    render_item_list buf _draw_items_ref "${CURRENT_TAB}" "$_vis_start" "$_vis_end"
    render_scroll_indicator buf "below" "$count" "$_vis_end"

    buf+=$'\n'"${C_CYAN} [Tab] Category  [r] Reset  [←/→ h/l] Adjust  [Enter] Toggle  [q] Quit${C_RESET}${CLR_EOL}"$'\n'
    buf+="${C_CYAN} File: ${C_WHITE}${CONFIG_FILE}${C_RESET}${CLR_EOL}${CLR_EOS}"
    printf '%s' "$buf"
}

draw_detail_view() {
    local buf="" pad_buf=""
    local -i count pad_needed
    local -i left_pad right_pad vis_len
    local -i _vis_start _vis_end

    buf+="${CURSOR_HOME}"
    buf+="${C_MAGENTA}┌${H_LINE}┐${C_RESET}${CLR_EOL}"$'\n'

    local title=" DETAIL VIEW "
    local sub=" ${CURRENT_MENU_ID} "
    strip_ansi "$title"; local -i t_len=${#REPLY}
    strip_ansi "$sub"; local -i s_len=${#REPLY}
    vis_len=$(( t_len + s_len ))
    left_pad=$(( (BOX_INNER_WIDTH - vis_len) / 2 ))
    right_pad=$(( BOX_INNER_WIDTH - vis_len - left_pad ))

    printf -v pad_buf '%*s' "$left_pad" ''
    buf+="${C_MAGENTA}│${pad_buf}${C_YELLOW}${title}${C_GREY}${sub}${C_MAGENTA}"
    printf -v pad_buf '%*s' "$right_pad" ''
    buf+="${pad_buf}│${C_RESET}${CLR_EOL}"$'\n'

    local breadcrumb=" « Back to ${TABS[CURRENT_TAB]}"
    strip_ansi "$breadcrumb"; local -i b_len=${#REPLY}
    pad_needed=$(( BOX_INNER_WIDTH - b_len ))
    if (( pad_needed < 0 )); then pad_needed=0; fi

    printf -v pad_buf '%*s' "$pad_needed" ''

    buf+="${C_MAGENTA}│${C_CYAN}${breadcrumb}${C_RESET}${pad_buf}${C_MAGENTA}│${C_RESET}${CLR_EOL}"$'\n'
    buf+="${C_MAGENTA}└${H_LINE}┘${C_RESET}${CLR_EOL}"$'\n'

    local items_var="SUBMENU_ITEMS_${CURRENT_MENU_ID}"
    local -n _detail_items_ref="$items_var"
    count=${#_detail_items_ref[@]}

    compute_scroll_window "$count"
    render_scroll_indicator buf "above" "$count" "$_vis_start"
    render_item_list buf _detail_items_ref "${CURRENT_MENU_ID}" "$_vis_start" "$_vis_end"
    render_scroll_indicator buf "below" "$count" "$_vis_end"

    buf+=$'\n'"${C_CYAN} [Esc/Sh+Tab] Back  [r] Reset  [←/→ h/l] Adjust  [Enter] Toggle  [q] Quit${C_RESET}${CLR_EOL}"$'\n'
    buf+="${C_CYAN} Submenu: ${C_WHITE}${CURRENT_MENU_ID}${C_RESET}${CLR_EOL}${CLR_EOS}"
    printf '%s' "$buf"
}

draw_ui() {
    case $CURRENT_VIEW in
        0) draw_main_view ;;
        1) draw_detail_view ;;
    esac
}

navigate() {
    local -i dir=$1
    local REPLY_REF REPLY_CTX
    get_active_context
    local -n _nav_items_ref="$REPLY_REF"
    local -i count=${#_nav_items_ref[@]}
    if (( count == 0 )); then return 0; fi
    SELECTED_ROW=$(( (SELECTED_ROW + dir + count) % count ))
}

navigate_page() {
    local -i dir=$1
    local REPLY_REF REPLY_CTX
    get_active_context
    local -n _navp_items_ref="$REPLY_REF"
    local -i count=${#_navp_items_ref[@]}
    if (( count == 0 )); then return 0; fi
    SELECTED_ROW=$(( SELECTED_ROW + dir * MAX_DISPLAY_ROWS ))
    if (( SELECTED_ROW < 0 )); then SELECTED_ROW=0; fi
    if (( SELECTED_ROW >= count )); then SELECTED_ROW=$(( count - 1 )); fi
}

navigate_end() {
    local -i target=$1
    local REPLY_REF REPLY_CTX
    get_active_context
    local -n _nave_items_ref="$REPLY_REF"
    local -i count=${#_nave_items_ref[@]}
    if (( count == 0 )); then return 0; fi
    if (( target == 0 )); then SELECTED_ROW=0; else SELECTED_ROW=$(( count - 1 )); fi
}

adjust() {
    local -i dir=$1
    local REPLY_REF REPLY_CTX
    get_active_context
    local -n _adj_items_ref="$REPLY_REF"
    if (( ${#_adj_items_ref[@]} == 0 )); then return 0; fi
    modify_value "${_adj_items_ref[SELECTED_ROW]}" "$dir"
}

switch_tab() {
    local -i dir=${1:-1}
    CURRENT_TAB=$(( (CURRENT_TAB + dir + TAB_COUNT) % TAB_COUNT ))
    SELECTED_ROW=0
    SCROLL_OFFSET=0
    load_active_values
}

set_tab() {
    local -i idx=$1
    if (( idx != CURRENT_TAB && idx >= 0 && idx < TAB_COUNT )); then
        CURRENT_TAB=$idx
        SELECTED_ROW=0
        SCROLL_OFFSET=0
        load_active_values
    fi
}

check_drilldown() {
    local -n _dd_items_ref="TAB_ITEMS_${CURRENT_TAB}"
    if (( ${#_dd_items_ref[@]} == 0 )); then return 1; fi

    local item="${_dd_items_ref[SELECTED_ROW]}"
    local config="${ITEM_MAP["${CURRENT_TAB}::${item}"]}"
    local key type
    IFS='|' read -r key type _ _ _ _ <<< "$config"

    if [[ "$type" == "menu" ]]; then
        PARENT_ROW=$SELECTED_ROW
        PARENT_SCROLL=$SCROLL_OFFSET

        CURRENT_MENU_ID="$key"
        CURRENT_VIEW=1
        SELECTED_ROW=0
        SCROLL_OFFSET=0
        load_active_values
        return 0
    fi
    return 1
}

go_back() {
    CURRENT_VIEW=0
    SELECTED_ROW=$PARENT_ROW
    SCROLL_OFFSET=$PARENT_SCROLL
    load_active_values
}

handle_mouse() {
    local input="$1"
    local -i button x y i start end
    local type zone

    local body="${input#'[<'}"
    if [[ "$body" == "$input" ]]; then return 0; fi
    local terminator="${body: -1}"
    if [[ "$terminator" != "M" && "$terminator" != "m" ]]; then return 0; fi
    body="${body%[Mm]}"
    local field1 field2 field3
    IFS=';' read -r field1 field2 field3 <<< "$body"
    if [[ ! "$field1" =~ ^[0-9]+$ ]]; then return 0; fi
    if [[ ! "$field2" =~ ^[0-9]+$ ]]; then return 0; fi
    if [[ ! "$field3" =~ ^[0-9]+$ ]]; then return 0; fi
    button=$field1; x=$field2; y=$field3

    if (( button == 64 )); then navigate -1; return 0; fi
    if (( button == 65 )); then navigate 1; return 0; fi
    if [[ "$terminator" != "M" ]]; then return 0; fi

    if (( y == TAB_ROW )); then
        if (( CURRENT_VIEW == 0 )); then
            # Arrow click handling for scrollable tabs
            if [[ -n "$LEFT_ARROW_ZONE" ]]; then
                start="${LEFT_ARROW_ZONE%%:*}"
                end="${LEFT_ARROW_ZONE##*:}"
                if (( x >= start && x <= end )); then switch_tab -1; return 0; fi
            fi
            if [[ -n "$RIGHT_ARROW_ZONE" ]]; then
                start="${RIGHT_ARROW_ZONE%%:*}"
                end="${RIGHT_ARROW_ZONE##*:}"
                if (( x >= start && x <= end )); then switch_tab 1; return 0; fi
            fi

            for (( i = 0; i < TAB_COUNT; i++ )); do
                if [[ -z "${TAB_ZONES[i]:-}" ]]; then continue; fi
                zone="${TAB_ZONES[i]}"
                start="${zone%%:*}"
                end="${zone##*:}"
                # Account for scroll offset in click target
                if (( x >= start && x <= end )); then set_tab "$(( i + TAB_SCROLL_START ))"; return 0; fi
            done
        else
            go_back
            return 0
        fi
    fi

    local -i effective_start=$(( ITEM_START_ROW + 1 ))
    if (( y >= effective_start && y < effective_start + MAX_DISPLAY_ROWS )); then
        local -i clicked_idx=$(( y - effective_start + SCROLL_OFFSET ))

        local _target_var_name
        if (( CURRENT_VIEW == 0 )); then
             _target_var_name="TAB_ITEMS_${CURRENT_TAB}"
        else
             _target_var_name="SUBMENU_ITEMS_${CURRENT_MENU_ID}"
        fi

        local -n _mouse_items_ref="$_target_var_name"

        local -i count=${#_mouse_items_ref[@]}
        if (( clicked_idx >= 0 && clicked_idx < count )); then
            SELECTED_ROW=$clicked_idx
            if (( x > ADJUST_THRESHOLD )); then
                if (( button == 0 )); then
                    if (( CURRENT_VIEW == 0 )); then
                        check_drilldown || adjust 1
                    else
                        adjust 1
                    fi
                else
                    adjust -1
                fi
            fi
        fi
    fi
    return 0
}

read_escape_seq() {
    local -n _esc_out=$1
    _esc_out=""
    local char
    if ! IFS= read -rsn1 -t "$ESC_READ_TIMEOUT" char; then
        return 1
    fi
    _esc_out+="$char"
    if [[ "$char" == '[' || "$char" == 'O' ]]; then
        while IFS= read -rsn1 -t "$ESC_READ_TIMEOUT" char; do
            _esc_out+="$char"
            if [[ "$char" =~ [a-zA-Z~] ]]; then break; fi
        done
    fi
    return 0
}

handle_key_main() {
    local key="$1"
    case "$key" in
        '[Z')                switch_tab -1; return ;;
        '[A'|'OA')           navigate -1; return ;;
        '[B'|'OB')           navigate 1; return ;;
        '[C'|'OC')           adjust 1; return ;;
        '[D'|'OD')           adjust -1; return ;;
        '[5~')               navigate_page -1; return ;;
        '[6~')               navigate_page 1; return ;;
        '[H'|'[1~')          navigate_end 0; return ;;
        '[F'|'[4~')          navigate_end 1; return ;;
        '['*'<'*[Mm])        handle_mouse "$key"; return ;;
    esac

    case "$key" in
        k|K)            navigate -1 ;;
        j|J)            navigate 1 ;;
        l|L)            adjust 1 ;;
        h|H)            adjust -1 ;;
        g)              navigate_end 0 ;;
        G)              navigate_end 1 ;;
        $'\t')          switch_tab 1 ;;
        r|R)            reset_defaults ;;
        ''|$'\n')       check_drilldown || adjust 1 ;;
        $'\x7f'|$'\x08'|$'\e\n') adjust -1 ;;
        q|Q|$'\x03')    exit 0 ;;
    esac
}

handle_key_detail() {
    local key="$1"
    case "$key" in
        '[A'|'OA')           navigate -1; return ;;
        '[B'|'OB')           navigate 1; return ;;
        '[C'|'OC')           adjust 1; return ;;
        '[D'|'OD')           adjust -1; return ;;
        '[5~')               navigate_page -1; return ;;
        '[6~')               navigate_page 1; return ;;
        '[H'|'[1~')          navigate_end 0; return ;;
        '[F'|'[4~')          navigate_end 1; return ;;
        '[Z')                go_back; return ;;
        '['*'<'*[Mm])        handle_mouse "$key"; return ;;
    esac

    case "$key" in
        ESC)            go_back ;;
        k|K)            navigate -1 ;;
        j|J)            navigate 1 ;;
        l|L)            adjust 1 ;;
        h|H)            adjust -1 ;;
        g)              navigate_end 0 ;;
        G)              navigate_end 1 ;;
        r|R)            reset_defaults ;;
        ''|$'\n')       adjust 1 ;;
        $'\x7f'|$'\x08'|$'\e\n') adjust -1 ;;
        q|Q|$'\x03')    exit 0 ;;
    esac
}

handle_input_router() {
    local key="$1"
    local escape_seq=""

    if [[ "$key" == $'\x1b' ]]; then
        if read_escape_seq escape_seq; then
            key="$escape_seq"
            if [[ "$key" == "" || "$key" == $'\n' ]]; then
                key=$'\e\n'
            fi
        else
            key="ESC"
        fi
    fi

    case $CURRENT_VIEW in
        0) handle_key_main "$key" ;;
        1) handle_key_detail "$key" ;;
    esac
}

main() {
    if (( BASH_VERSINFO[0] < 5 )); then log_err "Bash 5.0+ required"; exit 1; fi
    if [[ ! -t 0 ]]; then log_err "TTY required"; exit 1; fi
    if [[ ! -f "$CONFIG_FILE" ]]; then log_err "Config not found: $CONFIG_FILE"; exit 1; fi
    if [[ ! -w "$CONFIG_FILE" ]]; then log_err "Config not writable: $CONFIG_FILE"; exit 1; fi

    local _dep
    for _dep in awk; do
        if ! command -v "$_dep" &>/dev/null; then
            log_err "Missing dependency: ${_dep}"; exit 1
        fi
    done

    register_items
    populate_config_cache

    ORIGINAL_STTY=$(stty -g 2>/dev/null) || ORIGINAL_STTY=""
    stty -icanon -echo min 1 time 0 2>/dev/null

    printf '%s%s%s%s' "$MOUSE_ON" "$CURSOR_HIDE" "$CLR_SCREEN" "$CURSOR_HOME"
    load_active_values

    local key
    while true; do
        draw_ui
        IFS= read -rsn1 key || break
        handle_input_router "$key"
    done
}

main "$@"
