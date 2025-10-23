#!/usr/bin/env bash
#
# zfs-sentinel — Apply a ZFS property to multiple datasets
# Safe by default: dry-run unless --im-sure supplied (--dry-run forces dry-run)
# Single-pass arg parser, triple-lock safety, audit logging, debug, grep/glob/regex matching
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

# ---------- Defaults / flags ----------
LOGFILE="/var/log/zfs-sentinel.log"
NO_COLOR=false
NO_CLEAR=false
AUTO_YES=false
FORCE_DRY=false
APPLY=false
DEBUG=false
MODE="glob"            # glob|grep|regex
REQUIRED_TOKEN_FILE="/etc/zfs-sentinel/confirm.token"
TOKEN_FILE="${REQUIRED_TOKEN_FILE}"
ORIGINAL_CMD="$PROG_NAME $*"

# Parseable state
PROP=""                # property=value
PATTERN=""

# ---------- Helpers ----------
is_sensitive() {
    case "$1" in
        quota|refquota|reservation|refreservation|recordsize|logbias|primarycache|secondarycache) return 0 ;;
        *) return 1 ;;
    esac
}

mkdir -p "$(dirname "${LOGFILE}")" 2>/dev/null || true

audit_append() {
  local entry ts tmpdir tmpfile msg
  ts="$(date --iso-8601=seconds)"
  msg="$*"
  entry="$ts | UID=$(id -u) | PID=$$ | CMD=\"$ORIGINAL_CMD\" | $msg"
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/zfs-sentinel.XXXXXX" 2>/dev/null || true)"
  if [ -n "$tmpdir" ] && [ -d "$tmpdir" ]; then
    tmpfile="$tmpdir/entry"
    printf '%s\n' "$entry" > "$tmpfile" && mv "$tmpfile" "$LOGFILE"
    rm -rf "$tmpdir"
  else
    printf '%s\n' "$entry" >> "$LOGFILE"
  fi
  chmod 600 "$LOGFILE" 2>/dev/null || true
}

log_entry() {
    local level="$1"; shift
    local now; now="$(date --iso-8601=seconds)"
    local entry="[$now] level=$level uid=$(id -u) pid=$$ msg=\"$*\""
    if [ -n "$LOGFILE" ]; then
        printf '%s\n' "$entry" >> "$LOGFILE"
    fi
    if [ "$level" != "DEBUG" ]; then
        echo "$entry" >&2
    else
        [ "$DEBUG" = true ] && echo "$entry" >&2
    fi
}

debug() { [ "$DEBUG" = true ] && log_entry "DEBUG" "$*"; }
info()  { log_entry "INFO" "$*"; }
warn()  { log_entry "WARN" "$*"; }
error() { log_entry "ERROR" "$*"; }

run_cmd() {
    debug "run_cmd: $*"
    if [ "$FORCE_DRY" = true ] || [ "$APPLY" = false ]; then
        info "DRY-RUN: $*"
        return 0
    fi
    info "EXEC: $*"
    "$@"
}

show_help() {
    cat <<EOF
Usage: $PROG_NAME <property=value> <pattern> [options]

Matching modes:
  (default) glob — shell-style match, e.g. pool/ds/*
  -g, --grep       Plain substring match
  -x, --regex      Extended regex match (Bash [[ =~ ]])

Options:
  -h, --help           Show this help message
  --dry-run            Force dry-run mode (overrides --im-sure if both given)
  --im-sure            Actually apply changes (default is dry-run)
  --yes                Skip confirmation prompt (automation mode)
  --skip-token         Skip token requirement (requires --im-sure --yes together)
  --confirm=<token>    Provide confirm token inline
  --log <file>         Append audit log entries to <file>
  --no-color           Disable ANSI colors (plain text output)
  --no-clear           Do not clear the screen before confirmation
  --debug              Print parsed configuration and matched datasets

Examples:
  $PROG_NAME compression=lz4 oracle/secure*
  $PROG_NAME atime=off media -g
  $PROG_NAME recordsize=1M '^oracle/secure[0-9]+' -x --dry-run
EOF
}

# ---------- No-arg banner ----------
if [ $# -eq 0 ]; then
    echo -e "${C_BYELLOW}zfs-sentinel:${C_RESET} apply ZFS properties across multiple datasets at scale."
    echo
    echo "Run $PROG_NAME -h for full usage."
    exit 0
fi

# ---------- Single-pass arg parser ----------
# Accept short-style flags and GNU-style long flags; support --confirm token via = or next arg
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) show_help; exit 0 ;;
        -g|--grep) MODE="grep"; shift ;;
        -x|--regex) MODE="regex"; shift ;;
        --dry-run) FORCE_DRY=true; APPLY=false; shift ;;
        --im-sure) APPLY=true; shift ;;
        --yes) AUTO_YES=true; shift ;;
        --skip-token) SKIP_TOKEN=1; shift ;;
        --confirm=*) CONFIRM_TOKEN="${1#*=}"; shift ;;
        --confirm) CONFIRM_TOKEN="$2"; shift 2 ;;
        --log) LOGFILE="$2"; shift 2 ;;
        --no-color) NO_COLOR=true; shift ;;
        --no-clear) NO_CLEAR=true; shift ;;
        --debug) DEBUG=true; shift ;;
        --* ) echo -e "${C_BRED}Invalid flag${C_RESET} $1"; show_help; exit 3 ;;
        *)
            if [ -z "$PROP" ]; then
                PROP="$1"
            elif [ -z "$PATTERN" ]; then
                PATTERN="$1"
            else
                echo -e "${C_BRED}Unexpected extra argument:${C_RESET} $1"
                show_help
                exit 4
            fi
            shift
            ;;
    esac
done

# sanity checks
if [ -z "${PROP:-}" ] || [[ "$PROP" != *=* ]]; then
    echo -e "${C_BRED}Invalid or missing property:${C_RESET} ${PROP:-<none>}"
    echo "First argument must be property=value (e.g. compression=lz4)."
    exit 1
fi
if [ -z "${PATTERN:-}" ]; then
    echo -e "${C_BRED}Error:${C_RESET} dataset pattern is required."
    show_help
    exit 2
fi

# Apply color toggles
if [ "$NO_COLOR" = true ]; then
    C_RESET=""; C_BRED=""; C_BGREEN=""; C_BYELLOW=""; C_BMAGENTA=""; C_BCYAN=""
    BG_YELLOW=""; C_BLACK=""
fi

# canonicalize boolean defaults if not set earlier
APPLY=${APPLY:-false}
AUTO_YES=${AUTO_YES:-false}
FORCE_DRY=${FORCE_DRY:-false}
SKIP_TOKEN=${SKIP_TOKEN:-0}
CONFIRM_TOKEN=${CONFIRM_TOKEN:-""}

# ---------- Token resolution precedence: explicit flag > env > token file if exists ----------
TOKEN_PROVIDED="${CONFIRM_TOKEN:-${IM_SURE_TOKEN:-$( [ -f "$TOKEN_FILE" ] && sed -n '1p' "$TOKEN_FILE" || true )}}"
# trim CR/LF
TOKEN_PROVIDED="$(printf '%s' "$TOKEN_PROVIDED" | tr -d '\r\n')"

param="${PROP%%=*}"
val="${PROP#*=}"

# ---------- Gather datasets ----------
targets=$(zfs list -H -o name 2>/dev/null || true)
if [ -z "$targets" ]; then
    echo -e "${C_BRED}Error:${C_RESET} No ZFS datasets found (zfs list returned empty)." >&2
    exit 6
fi

matched=()
while IFS= read -r ds; do
    case "$MODE" in
        glob)  [[ "$ds" == $PATTERN ]] && matched+=("$ds") ;;
        grep)  [[ "$ds" == *"$PATTERN"* ]] && matched+=("$ds") ;;
        regex) [[ "$ds" =~ $PATTERN ]] && matched+=("$ds") ;;
    esac
done <<< "$targets"

if [ ${#matched[@]} -eq 0 ]; then
    echo "No datasets matched pattern: $PATTERN"
    exit 7
fi

# ---------- Debug dump ----------
if [ "$DEBUG" = true ]; then
    echo "----- DEBUG -----"
    echo "Property: $PROP"
    echo "  Param: $param"
    echo "  Value: $val"
    echo "Pattern: $PATTERN"
    echo "Mode: $MODE"
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

# ---------- Preflight checks ----------
preflight_checks() {
    if ! zfs list -H -o name "${matched[0]}" >/dev/null 2>&1; then
        error "Dataset ${matched[0]} was expected but is missing."
        exit 8
    fi
    pool=$(printf '%s\n' "${matched[0]}" | cut -d/ -f1)
    if command -v zpool >/dev/null 2>&1; then
        free_bytes=$(zpool list -H -o free "$pool" 2>/dev/null || echo "0")
        debug "preflight: pool=$pool free=$free_bytes"
    else
        debug "preflight: zpool not available to check free space"
    fi
    info "Preflight checks passed for pattern: $PATTERN"
}

# ---------- Sensitive property checks and token enforcement ----------
SENSITIVE=false
if is_sensitive "$param"; then
    debug "sensitive property detected: $param"
    SENSITIVE=true
fi

if [ "$SENSITIVE" = true ]; then
    if [ "$SKIP_TOKEN" -eq 1 ] && [ "$APPLY" = true ] && [ "$AUTO_YES" = true ]; then
        echo -e "${C_BYELLOW}WARNING:${C_RESET} Sensitive property change WITHOUT token; SKIP_TOKEN used."
        audit_append "SKIP_TOKEN used; PROP=$param"
    else
        if [ ! -f "$TOKEN_FILE" ]; then
            echo -e "${C_BRED}Error:${C_RESET} Required token file $TOKEN_FILE missing for sensitive property." >&2
            echo "Provide --confirm <token>, set IM_SURE_TOKEN, create $TOKEN_FILE, or use --skip-token --im-sure --yes to force."
            exit 9
        fi
        EXPECTED_TOKEN="$(sed -n '1p' "$TOKEN_FILE" 2>/dev/null || true)"
        EXPECTED_TOKEN="$(printf '%s' "$EXPECTED_TOKEN" | tr -d '\r\n')"
        if [ -z "$EXPECTED_TOKEN" ]; then
            echo -e "${C_BRED}Error:${C_RESET} Token file $TOKEN_FILE exists but is empty." >&2
            exit 10
        fi
        if [ -z "$TOKEN_PROVIDED" ]; then
            if [ -t 0 ]; then
                echo -e "${C_BYELLOW}Sensitive change detected.${C_RESET} Provide token via --confirm or IM_SURE_TOKEN env var, or type it now."
                read -s -p "Enter confirm token: " typed_token
                echo
                TOKEN_PROVIDED="$typed_token"
            fi
        fi
        if [ "$TOKEN_PROVIDED" != "$EXPECTED_TOKEN" ]; then
            echo -e "${C_BRED}Error:${C_RESET} Confirmation token did not match. Aborting." >&2
            exit 11
        fi
    fi
fi

# ---------- Print preview and handle dry-run/apply decision ----------
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
        if [ $color -eq 0 ]; then fmt="$C_BCYAN"; else fmt="$C_BYELLOW"; fi
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

# If not applying or forced dry-run, show preview and exit
if [ "$APPLY" = false ] || [ "$FORCE_DRY" = true ]; then
    print_preview "${C_BYELLOW}Running in DRY-MODE:${C_RESET} Applying"
    echo "If the results are accurate you can bypass the dry-run safety using --im-sure"
    echo
    exit 0
fi

# ---------- Interactive typed confirmation unless AUTO_YES true or non-tty ----------
if [ -t 0 ] && [ "$AUTO_YES" = false ]; then
    if [ "$NO_CLEAR" = false ]; then printf "\033c"; fi
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
    [ "$AUTO_YES" = true ] && echo -e "${C_BYELLOW}--yes flag detected: skipping interactive confirmation.${C_RESET}"
    [ "$NO_CLEAR" = false ] && printf "\033c"
fi

preflight_checks

# ---------- Apply with progress ----------
count=${#matched[@]}
i=0
sp="/-\|"
echo
for ds in "${matched[@]}"; do
    i=$((i+1))
    if ! run_cmd zfs set "$PROP" "$ds"; then
        warn "Failed to set $PROP on $ds (continuing)"
    else
        debug "Set $PROP on $ds succeeded"
    fi
    pct=$(( (100 * i) / count ))
    s="${sp:$((i % ${#sp})):1}"
    printf "\r[%s] %d/%d (%d%%) -> %s" "$s" "$i" "$count" "$pct" "$ds"
done
echo -e "\n${C_BGREEN}Done.${C_RESET}"

# ---------- Structured logging summary ----------
if [ -n "$LOGFILE" ]; then
    {
        echo "---- zfs-sentinel run: $(date '+%Y-%m-%d %H:%M:%S') ----"
        echo "Cmd: $ORIGINAL_CMD"
        echo "User: $(id -u) ($(id -un)) pid=$$"
        echo "Applied: $PROP"
        echo "Count: $count"
        printf '  %s\n' "${matched[@]}"
        echo
    } >> "$LOGFILE"
    info "Audit written to $LOGFILE"
fi

exit 0
