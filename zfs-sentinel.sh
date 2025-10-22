#!/usr/bin/env bash
#
# zfs-sentinel — Apply a ZFS property to multiple datasets
# Safe by default: dry-run unless --im-sure supplied (--dry-run forces dry-run)
# Triple-lock safety, audit logging, debug, grep/glob/regex matching
#

set -o errexit
set -o nounset
set -o pipefail

PROG_NAME="$(basename "$0")"
# ---------- Color Palette ----------
C_RESET="\033[0m"
C_BRED="\033[1;31m";    C_BGREEN="\033[1;32m";  C_BYELLOW="\033[1;33m"
C_BMAGENTA="\033[1;35m";C_BCYAN="\033[1;36m"
BG_YELLOW="\033[43m";   C_BLACK="\033[0;30m"

LOGFILE=""
NO_COLOR=false
NO_CLEAR=false
AUTO_YES=false
FORCE_DRY=false
APPLY=false
DEBUG=false

# default expected token file for destructive ops (operator-managed)
REQUIRED_TOKEN_FILE="/etc/zfs-sentinel/confirm.token"

show_help() {
    cat <<EOF
Usage: $PROG_NAME <property=value> <pattern> [options]

Matching modes:
  (default) glob — shell-style match, e.g. pool/ds/*
  -g, --grep       Plain substring match
  -x, --regex      Extended regex match (Bash [[ =~ ]])

Options:
  -h, --help       Show this help message
  --dry-run        Force dry-run mode (overrides --im-sure if both given)
  --im-sure        Actually apply changes (default is dry-run)
  --yes            Skip confirmation prompt (automation mode)
  --log <file>     Append audit log entries to <file>
  --no-color       Disable ANSI colors (plain text output)
  --no-clear       Do not clear the screen before confirmation
  --debug          Print parsed configuration and matched datasets

Examples:
  $PROG_NAME compression=lz4 oracle/secure*                 
  $PROG_NAME atime=off media -g                             
  $PROG_NAME recordsize=1M '^oracle/secure[0-9]+' -x --dry-run
  $PROG_NAME recordsize=1M '^oracle/secure[0-9]+' -x --im-sure --yes --log /var/log/zfs-sentinel.log
EOF
}

# ---------- No-arg intro banner ----------
if [ $# -eq 0 ]; then
    echo -e "${C_BYELLOW}zfs-sentinel:${C_RESET} apply ZFS properties across multiple datasets at scale."
    echo
    echo "This tool previews and safely applies changes like:"
    echo "  zfs-sentinel compression=lz4 pool/dataset/*"
    echo
    echo "Run $PROG_NAME -h for full usage."
    exit 0
fi

# ---------- Early help handling ----------
if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    show_help
    exit 0
fi

# ---------- Arg precheck ----------
# First arg must be property=value (reject missing '=')
if [[ "$1" != *=* ]]; then
    echo -e "${C_BRED}Invalid or missing property:${C_RESET} $1"
    echo "First argument must be property=value (e.g. compression=lz4)."
    echo "Use -h or --help for usage."
    exit 1
fi

prop="$1"
shift

mode="glob"
pattern=""

# ---------- Parse args with invalid-flag handling ----------
while [ $# -gt 0 ]; do
    case "$1" in
        -g|--grep) mode="grep" ;;
        -x|--regex) mode="regex" ;;
        -h|--help) show_help; exit 0 ;;
        --im-sure) APPLY=true ;;
        --dry-run) FORCE_DRY=true ;;
        --log)
            shift
            if [ $# -eq 0 ] || [ -z "$1" ]; then
                echo -e "${C_BRED}Error:${C_RESET} --log requires a file path."
                exit 2
            fi
            LOGFILE="$1"
            ;;
        --no-color) NO_COLOR=true ;;
        --no-clear) NO_CLEAR=true ;;
        --yes) AUTO_YES=true ;;
        --debug) DEBUG=true ;;
        -*)
            echo -e "${C_BRED}Invalid flag${C_RESET} $1"
            echo "Please use -h or --help for more info."
            exit 3
            ;;
        *)
            if [ -z "$pattern" ]; then
                pattern="$1"
            else
                echo -e "${C_BRED}Unexpected extra argument:${C_RESET} $1"
                echo "Please use -h or --help for usage."
                exit 4
            fi
            ;;
    esac
    shift
done

if [ -z "$pattern" ]; then
    echo "Error: dataset pattern is required."
    show_help
    exit 5
fi

# ---------- Color disable ----------
if [ "$NO_COLOR" = true ]; then
    C_RESET=""; C_BRED=""; C_BGREEN=""; C_BYELLOW=""; C_BMAGENTA=""; C_BCYAN=""
    BG_YELLOW=""; C_BLACK=""
fi

# ---------- Helpers: logging, debug, run wrapper ----------
mkdir -p "$(dirname "${LOGFILE:-/var/log/zfs-sentinel.log}")" 2>/dev/null || true

log_entry() {
    local level="$1"; shift
    local now; now="$(date --iso-8601=seconds)"
    local entry="[$now] level=$level uid=$(id -u) pid=$$ cmd=\"$*\""
    if [ -n "$LOGFILE" ]; then
        printf '%s\n' "$entry" >> "$LOGFILE"
    fi
    # always echo INFO/WARN/ERROR to stderr for visibility
    if [ "$level" != "DEBUG" ]; then
        echo "$entry" >&2
    else
        if [ "$DEBUG" = true ]; then
            echo "$entry" >&2
        fi
    fi
}

debug() {
    [ "$DEBUG" = true ] && log_entry "DEBUG" "$*"
}

info()  { log_entry "INFO" "$*"; }
warn()  { log_entry "WARN" "$*"; }
error() { log_entry "ERROR" "$*"; }

# run wrapper respects FORCE_DRY and logs actions; returns command exit status
run_cmd() {
    debug "run_cmd: $*"
    if [ "$FORCE_DRY" = true ] || [ "$APPLY" = false ]; then
        info "DRY-RUN: $*"
        return 0
    fi
    info "EXEC: $*"
    "$@"
}

# ---------- Gather targets ----------
targets=$(zfs list -H -o name 2>/dev/null || true)
if [ -z "$targets" ]; then
    echo -e "${C_BRED}Error:${C_RESET} No ZFS datasets found (zfs list returned empty)." >&2
    exit 6
fi

matched=()
while IFS= read -r ds; do
    case "$mode" in
        glob)  [[ "$ds" == $pattern ]] && matched+=("$ds") ;;
        grep)  [[ "$ds" == *"$pattern"* ]] && matched+=("$ds") ;;
        regex) [[ "$ds" =~ $pattern ]] && matched+=("$ds") ;;
    esac
done <<< "$targets"

if [ ${#matched[@]} -eq 0 ]; then
    echo "No datasets matched pattern: $pattern"
    exit 7
fi

# ---------- Split property ----------
param="${prop%%=*}"
val="${prop#*=}"

# ---------- Debug dump ----------
if [ "$DEBUG" = true ]; then
    echo "----- DEBUG -----"
    echo "Property: $prop"
    echo "  Param: $param"
    echo "  Value: $val"
    echo "Pattern: $pattern"
    echo "Mode: $mode"
    echo "Apply (--im-sure): $APPLY"
    echo "Force dry-run: $FORCE_DRY"
    echo "Auto-Yes: $AUTO_YES"
    echo "No-Color: $NO_COLOR"
    echo "No-Clear: $NO_CLEAR"
    echo "Logfile: ${LOGFILE:-<none>}"
    echo "Matched count: ${#matched[@]}"
    printf 'Matched datasets:\n  %s\n' "${matched[@]}"
    echo "-----------------"
fi

# ---------- Preview Function ----------
print_preview() {
    local header="$1"
    echo
    echo -e "$header ${C_BMAGENTA}${param}${C_RESET}=${C_BGREEN}${val}${C_RESET} to the following datasets:"
    echo

    cols=$(tput cols 2>/dev/null || echo 80)
    line=""
    i=0
    for ds in "${matched[@]}"; do
        color=$(( i % 2 ))
        if [ $color -eq 0 ]; then
            fmt="$C_BCYAN"
        else
            fmt="$C_BYELLOW"
        fi
        entry="${fmt}${ds}${C_RESET}    "
        if [ $((${#line} + ${#ds} + 5)) -ge $cols ]; then
            echo -e "$line"
            line="$entry"
        else
            line="$line$entry"
        fi
        i=$((i+1))
    done
    [ -n "$line" ] && echo -e "$line"
    echo

    echo -e "${BG_YELLOW}${C_BLACK} WARNING ${C_RESET} ZFS parameters can cause disruptions, disconnects, and even data-loss if misused."
    echo -e "          Know the implications before applying!"
    echo
}

# ---------- Preflight checks ----------
preflight_checks() {
    # spot-check first matched dataset exists (should be true already)
    if ! zfs list -H -o name "${matched[0]}" >/dev/null 2>&1; then
        error "Dataset ${matched[0]} was expected but is missing."
        exit 8
    fi

    # check pool free (best-effort): try to find pool name and zpool list
    pool=$(printf '%s\n' "${matched[0]}" | cut -d/ -f1)
    if command -v zpool >/dev/null 2>&1; then
        free_bytes=$(zpool list -H -o free "$pool" 2>/dev/null || echo "0")
        debug "preflight: pool=$pool free=$free_bytes"
    else
        debug "preflight: zpool not available to check free space"
    fi

    info "Preflight checks passed for pattern: $pattern"
}

# ---------- Dry-run (default unless APPLY true and not forced dry) ----------
if [ "$APPLY" = false ] || [ "$FORCE_DRY" = true ]; then
    print_preview "${C_BYELLOW}Running in DRY-MODE:${C_RESET} Applying"
    echo "If the results are accurate you can bypass the dry-run safety using --im-sure"
    echo
    exit 0
fi

# ---------- Destructive action safeguards ----------
# If operation involves a property that is potentially destructive, require token
# Heuristic: treat any property named 'quota' 'refquota' 'reservation' 'refreservation' 'logbias' 'primarycache' 'secondarycache' or 'recordsize' as sensitive
sensitive_props="quota refquota reservation refreservation recordsize logbias primarycache secondarycache"
for p in $sensitive_props; do
    if [ "$param" = "$p" ]; then
        debug "sensitive property detected: $param"
        SENSITIVE=true
        break
    fi
done
SENSITIVE=${SENSITIVE:-false}

if [ "$SENSITIVE" = true ]; then
    if [ ! -f "$REQUIRED_TOKEN_FILE" ]; then
        echo -e "${C_BRED}Error:${C_RESET} Required token file $REQUIRED_TOKEN_FILE missing for sensitive property." >&2
        exit 9
    fi
    EXPECTED_TOKEN="$(sed -n '1p' "$REQUIRED_TOKEN_FILE" 2>/dev/null || true)"
    if [ -z "$EXPECTED_TOKEN" ]; then
        echo -e "${C_BRED}Error:${C_RESET} Token file $REQUIRED_TOKEN_FILE exists but is empty." >&2
        exit 10
    fi
    # require operator to pass token via environment variable IM_SURE_TOKEN or ask interactively
    if [ -z "${IM_SURE_TOKEN:-}" ]; then
        echo -e "${C_BYELLOW}Sensitive change detected.${C_RESET} Provide token via IM_SURE_TOKEN environment variable or type it now."
        read -s -p "Enter confirm token: " typed_token
        echo
        IM_SURE_TOKEN="$typed_token"
    fi
    if [ "$IM_SURE_TOKEN" != "$EXPECTED_TOKEN" ]; then
        echo -e "${C_BRED}Error:${C_RESET} Confirmation token did not match. Aborting." >&2
        exit 11
    fi
fi

# Interactive typed confirmation (third lock) when TTY and not auto-yes
if [ -t 0 ] && [ "$AUTO_YES" = false ]; then
    if [ "$NO_CLEAR" = false ]; then
        # clear screen for confirmation
        printf "\033c"
    fi
    print_preview "${C_BRED}You are about to apply${C_RESET}"
    read -r -p "Type the dataset count (${#matched[@]}) to confirm, or type ABORT to cancel: " resp
    if [[ "$resp" == "ABORT" ]]; then
        echo "Aborted by operator."
        exit 12
    fi
    if [[ "$resp" != "${#matched[@]}" ]]; then
        echo "Confirmation mismatch; expected dataset count. Aborting." >&2
        exit 13
    fi
else
    if [ "$AUTO_YES" = true ]; then
        echo -e "${C_BYELLOW}--yes flag detected: skipping interactive confirmation.${C_RESET}"
    fi
    if [ "$NO_CLEAR" = false ]; then
        printf "\033c"
    fi
fi

# final preflight
preflight_checks

# ---------- Apply with progress ----------
count=${#matched[@]}
i=0
sp="/-\|"
echo
for ds in "${matched[@]}"; do
    i=$((i+1))
    # wrap in run_cmd to handle dry-run vs execute and logging
    if ! run_cmd zfs set "$prop" "$ds"; then
        warn "Failed to set $prop on $ds (continuing)"
        # continue to next dataset; do not abort entire run
    else
        debug "Set $prop on $ds succeeded"
    fi
    pct=$(( (100 * i) / count ))
    # spinner char
    s="${sp:$((i % ${#sp})):1}"
    printf "\r[%s] %d/%d (%d%%) -> %s" "$s" "$i" "$count" "$pct" "$ds"
done
echo -e "\n${C_BGREEN}Done.${C_RESET}"

# ---------- Structured logging summary ----------
if [ -n "$LOGFILE" ]; then
    {
        echo "---- zfs-sentinel run: $(date '+%Y-%m-%d %H:%M:%S') ----"
        echo "Cmd: $PROG_NAME $*"
        echo "User: $(id -u) ($(id -un)) pid=$$"
        echo "Applied: $prop"
        echo "Count: $count"
        printf '  %s\n' "${matched[@]}"
        echo
    } >> "$LOGFILE"
    info "Audit written to $LOGFILE"
fi

exit 0
