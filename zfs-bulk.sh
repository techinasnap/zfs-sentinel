#!/bin/bash
#
# zfs-bulk — Apply a ZFS property to multiple datasets
# Default: dry-run (prints preview only)
# Use --im-sure to actually apply changes
# Supports glob/grep/regex matching, logging, --no-color, --no-clear, --yes, --dry-run, --debug
#

# ---------- Color Palette ----------
C_RESET="\033[0m"
C_BRED="\033[1;31m";    C_BGREEN="\033[1;32m";  C_BYELLOW="\033[1;33m"
C_BMAGENTA="\033[1;35m";C_BCYAN="\033[1;36m"
BG_YELLOW="\033[43m";   C_BLACK="\033[0;30m"

# ---------- Theme Guide ----------
# Parameters:   C_BMAGENTA
# Values:       C_BGREEN
# Dataset alt1: C_BCYAN
# Dataset alt2: C_BYELLOW
# Warnings:     BG_YELLOW + C_BLACK
# Success:      C_BGREEN
# ---------------------------------

LOGFILE=""
NO_COLOR=false
NO_CLEAR=false
AUTO_YES=false
FORCE_DRY=false
DEBUG=false

show_help() {
    cat <<EOF
Usage: zfs-bulk <property=value> <pattern> [options]

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
  zfs-bulk compression=lz4 oracle/secure*                 # glob match (default)
  zfs-bulk atime=off media -g                             # grep substring
  zfs-bulk recordsize=1M '^oracle/secure[0-9]+' -x --dry-run
  zfs-bulk recordsize=1M '^oracle/secure[0-9]+' -x --im-sure --yes --log /var/log/zfs-bulk.log
EOF
}

# ---------- No-arg intro banner ----------
if [ $# -eq 0 ]; then
    echo -e "${C_BYELLOW}zfs-bulk:${C_RESET} bulk apply ZFS properties across multiple datasets."
    echo
    echo "This tool lets you preview and safely apply changes like:"
    echo "  zfs-bulk compression=lz4 pool/dataset/*"
    echo
    echo "Why use it?"
    echo "  • Safe by default: runs in dry-run mode unless you add --im-sure"
    echo "  • Operator-friendly: color-coded previews, warnings, and audit logs"
    echo "  • Flexible matching: glob, grep, or regex dataset selection"
    echo
    echo "For full usage and options, run: zfs-bulk -h"
    exit 0
fi

# ---------- Arg precheck ----------
# First arg must be property=value (reject flags/missing '=')
if [[ "$1" == -* ]] || [[ "$1" != *=* ]]; then
    echo -e "${C_BRED}Invalid flag or missing property:${C_RESET} $1"
    echo "First argument must be property=value (e.g. compression=lz4)."
    echo "Use -h or --help for usage."
    exit 1
fi

prop="$1"
shift

mode="glob"
apply=false
pattern=""

# ---------- Parse args with invalid-flag handling ----------
while [ $# -gt 0 ]; do
    case "$1" in
        -g|--grep) mode="grep" ;;
        -x|--regex) mode="regex" ;;
        -h|--help) show_help; exit 0 ;;
        --im-sure) apply=true ;;
        --dry-run) FORCE_DRY=true ;;
        --log)
            shift
            if [ -z "$1" ]; then
                echo -e "${C_BRED}Error:${C_RESET} --log requires a file path."
                exit 1
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
            exit 1
            ;;
        *)
            if [ -z "$pattern" ]; then
                pattern="$1"
            else
                echo -e "${C_BRED}Unexpected extra argument:${C_RESET} $1"
                echo "Please use -h or --help for usage."
                exit 1
            fi
            ;;
    esac
    shift
done

if [ -z "$pattern" ]; then
    echo "Error: dataset pattern is required."
    show_help
    exit 1
fi

# ---------- Color disable ----------
if [ "$NO_COLOR" = true ]; then
    C_RESET=""; C_BRED=""; C_BGREEN=""; C_BYELLOW=""; C_BMAGENTA=""; C_BCYAN=""
    BG_YELLOW=""; C_BLACK=""
fi

# ---------- Gather targets ----------
targets=$(zfs list -H -o name 2>/dev/null)
if [ -z "$targets" ]; then
    echo -e "${C_BRED}Error:${C_RESET} No ZFS datasets found (zfs list returned empty)."
    exit 1
fi

matched=()
for ds in $targets; do
    case "$mode" in
        glob)  [[ "$ds" == $pattern ]] && matched+=("$ds") ;;
        grep)  [[ "$ds" == *"$pattern"* ]] && matched+=("$ds") ;;
        regex) [[ "$ds" =~ $pattern ]] && matched+=("$ds") ;;
    esac
done

if [ ${#matched[@]} -eq 0 ]; then
    echo "No datasets matched pattern: $pattern"
    exit 1
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
    echo "Apply (--im-sure): $apply"
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

    # Highlighted warning banner
    echo -e "${BG_YELLOW}${C_BLACK} WARNING ${C_RESET} ZFS parameters can cause disruptions, disconnects, and even data-loss if misused."
    echo -e "          You can also impact how data is written to disk, affecting performance."
    echo -e "          Know the implications before applying!"
    echo
}

# ---------- Dry-run (default or forced) ----------
if [ "$apply" = false ] || [ "$FORCE_DRY" = true ]; then
    print_preview "${C_BYELLOW}Running in DRY-MODE:${C_RESET} Applying"
    echo "If the results are accurate you can bypass the dry-run safety using --im-sure"
    echo
    exit 0
fi

# ---------- Live run ----------
# Clear unless disabled
if [ "$NO_CLEAR" = false ]; then
    printf "\033c"
else
    echo -e "${C_BYELLOW}Leave my screen alone mode enabled — not clearing screen.${C_RESET}"
fi

# Preview + confirm (unless --yes)
print_preview "${C_BRED}You are about to apply${C_RESET}"

if [ "$AUTO_YES" = false ]; then
    read -p "Are you sure you wish to continue? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi
else
    echo -e "${C_BYELLOW}--yes flag detected: skipping confirmation prompt.${C_RESET}"
fi

# Apply with spinner/progress
count=${#matched[@]}
i=0
sp="/-\|"
echo
for ds in "${matched[@]}"; do
    i=$((i+1))
    zfs set "$prop" "$ds"
    pct=$(( (100*i)/count ))
    printf "\r[%c] %d/%d (%d%%)" "${sp:i%${#sp}:1}" "$i" "$count" "$pct"
    sleep 0.05
done
echo -e "\n${C_BGREEN}Done.${C_RESET}"

# Logging
if [ -n "$LOGFILE" ]; then
    {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Applied '$prop' to ${#matched[@]} dataset(s):"
        printf '  %s\n' "${matched[@]}"
        echo
    } >> "$LOGFILE"
fi
