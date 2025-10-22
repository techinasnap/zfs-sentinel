#!/usr/bin/env bash
#
# zfs-sentinel — Apply a ZFS property to multiple datasets
# Safe by default: dry-run unless --im-sure supplied (--dry-run forces dry-run)
# Triple-lock safety, audit logging, debug, grep/glob/regex matching
#
# shellcheck disable=SC2086  # Word splitting is intentional for pattern matching
# shellcheck disable=SC2046  # Word splitting is intentional for dataset lists
# shellcheck enable=require-variable-braces
# shellcheck enable=check-set-e-suppressed

VERSION="1.0.0"

set -o errexit
set -o nounset
set -o pipefail

# Default timeout for operations (in seconds)
DEFAULT_TIMEOUT=300

# Temporary files/locks that need cleanup
declare -a TEMP_FILES=()
declare -a LOCK_FILES=()
LOCK_DIR="/var/run/zfs-sentinel"
PID_FILE=""

# Minimal logging stubs to allow cleanup/traps to run before full logger is defined.
# These are overridden later by the real implementations.
DEBUG=false
log_entry() { :; }
debug() { :; }
info() { :; }
warn() { :; }
error() { echo "ERROR: $*" >&2; }

# Handle cleanup on script exit
cleanup() {
    local exit_code="${1:-0}"
    local error_msg="${2:-}"
    
    # 1. Log the cleanup start
    debug "Starting cleanup (exit code: $exit_code, error: $error_msg)"
    
    # 2. Kill background processes
    if jobs -p &>/dev/null; then
        debug "Killing background processes..."
        kill "$(jobs -p)" 2>/dev/null || true
    fi
    
    # 3. Remove temporary files
    if [ ${#TEMP_FILES[@]} -gt 0 ]; then
        debug "Removing temporary files..."
        for tmp in "${TEMP_FILES[@]}"; do
            if [ -f "$tmp" ]; then
                rm -f "$tmp" 2>/dev/null || debug "Failed to remove temp file: $tmp"
            fi
        done
    fi
    
    # 4. Remove lock files
    if [ ${#LOCK_FILES[@]} -gt 0 ]; then
        debug "Removing lock files..."
        for lock in "${LOCK_FILES[@]}"; do
            if [ -f "$lock" ]; then
                rm -f "$lock" 2>/dev/null || debug "Failed to remove lock file: $lock"
            fi
        done
    fi
    
    # 5. Remove PID file if we created one
    if [ -n "$PID_FILE" ] && [ -f "$PID_FILE" ]; then
        debug "Removing PID file: $PID_FILE"
        rm -f "$PID_FILE" 2>/dev/null || debug "Failed to remove PID file"
    fi
    
    # 6. Log completion status
    if [ "$exit_code" -ne 0 ]; then
        error "Cleanup completed with errors (exit code: $exit_code, error: $error_msg)"
    else
        debug "Cleanup completed successfully"
    fi
    
    exit "$exit_code"
}

# Create temporary file with cleanup registration
make_temp_file() {
    local tmp
    tmp=$(mktemp) || {
        error "Failed to create temporary file"
        return 1
    }
    TEMP_FILES+=("$tmp")
    echo "$tmp"
}

# Create and register lock file
create_lock() {
    local lock_name="$1"
    local lock_file="$LOCK_DIR/$lock_name.lock"
    
    # Ensure lock directory exists
    mkdir -p "$LOCK_DIR" 2>/dev/null || {
        error "Failed to create lock directory: $LOCK_DIR"
        return 1
    }
    
    # Create lock file with PID
    echo "$$" > "$lock_file" 2>/dev/null || {
        error "Failed to create lock file: $lock_file"
        return 1
    }
    
    LOCK_FILES+=("$lock_file")
    return 0
}

# Check current resource usage and state
check_resources() {
    local check_type="${1:-all}"  # all, temp, locks, processes
    local verbose="${2:-false}"
    
    echo -e "\n${C_BYELLOW}Resource Check Report${C_RESET}"
    echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Process ID: $$"
    
    case "$check_type" in
        "all"|"temp")
            echo -e "\n${C_BCYAN}Temporary Files:${C_RESET}"
            if [ ${#TEMP_FILES[@]} -eq 0 ]; then
                echo "  No temporary files registered"
            else
                for tmp in "${TEMP_FILES[@]}"; do
                    if [ -f "$tmp" ]; then
                        local size
                        size=$(stat -f %z "$tmp" 2>/dev/null || stat -c %s "$tmp" 2>/dev/null || echo "unknown")
                        echo -e "  ${C_BGREEN}✓${C_RESET} $tmp (size: $size bytes)"
                    else
                        echo -e "  ${C_BRED}✗${C_RESET} $tmp (missing)"
                    fi
                done
            fi
            ;;
    esac
    
    case "$check_type" in
        "all"|"locks")
            echo -e "\n${C_BCYAN}Lock Files:${C_RESET}"
            if [ ${#LOCK_FILES[@]} -eq 0 ]; then
                echo "  No lock files registered"
            else
                for lock in "${LOCK_FILES[@]}"; do
                    if [ -f "$lock" ]; then
                        local pid
                        pid=$(cat "$lock" 2>/dev/null || echo "unreadable")
                        echo -e "  ${C_BGREEN}✓${C_RESET} $lock (PID: $pid)"
                    else
                        echo -e "  ${C_BRED}✗${C_RESET} $lock (missing)"
                    fi
                done
            fi
            ;;
    esac
    
    case "$check_type" in
        "all"|"processes")
            echo -e "\n${C_BCYAN}Background Processes:${C_RESET}"
            local bg_procs
            bg_procs=$(jobs -p)
            if [ -z "$bg_procs" ]; then
                echo "  No background processes"
            else
                while IFS= read -r pid; do
                    if [ -n "$pid" ]; then
                        local cmd
                        cmd=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
                        echo -e "  ${C_BGREEN}✓${C_RESET} PID $pid ($cmd)"
                    fi
                done <<< "$bg_procs"
            fi
            ;;
    esac
    
    if [ "$verbose" = "true" ]; then
        echo -e "\n${C_BCYAN}System Resources:${C_RESET}"
        echo "  Open Files: $(lsof -p $$ 2>/dev/null | wc -l)"
        echo "  Memory Usage: $(ps -o rss= -p $$ 2>/dev/null || echo "unknown") KB"
        echo "  CPU Time: $(ps -o time= -p $$ 2>/dev/null || echo "unknown")"
    fi
    
    echo -e "\n${C_BYELLOW}End Resource Report${C_RESET}\n"
}

# Timeout handler
handle_timeout() {
    echo -e "\n${C_BRED}Error:${C_RESET} Operation timed out after ${TIMEOUT:-$DEFAULT_TIMEOUT} seconds"
    cleanup 21
}

# Environment validation
validate_environment() {
    # Check if we're running with sufficient privileges
    if [ "$(id -u)" -ne 0 ] && ! groups | grep -q zfs; then
        echo -e "${C_BRED}Error:${C_RESET} Must run as root or user in 'zfs' group"
        exit 22
    fi

    # Ensure TERM is set for tput
    if [ -z "${TERM:-}" ]; then
        export TERM=dumb
    fi

    # Check if custom timeout is valid
    if [ -n "${TIMEOUT:-}" ] && ! [[ "$TIMEOUT" =~ ^[0-9]+$ ]]; then
        echo -e "${C_BRED}Error:${C_RESET} TIMEOUT must be a positive integer"
        exit 23
    fi
}

trap 'cleanup $?' EXIT
trap 'cleanup 1' INT TERM
trap 'handle_timeout' ALRM

PROG_NAME="$(basename "$0")"

# ---------- Required Command Validation ----------
check_required_commands() {
    local missing=()
    local required_cmds=(
        "zfs"
        "zpool"
        "mkdir"
        "chmod"
        "chown"
        "date"
        "tput"
        "sed"
        "cut"
        "head"
        "base64"
        "printf"
        "read"
        "free"      # For memory monitoring
        "qm"        # Proxmox VM management
        "pct"       # Proxmox CT management
        "pvesh"     # Proxmox API shell
    )

    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        echo -e "${C_BRED}Error:${C_RESET} Required commands missing:"
        printf '  %s\n' "${missing[@]}"
        exit 20
    fi
}

# ---------- Proxmox Environment Checks ----------
# EPYC 7513 NPS1 Mode Optimized Thresholds
MEMORY_THRESHOLD=94     # Higher threshold for single NUMA domain
IO_WAIT_THRESHOLD=15    # EPYC 7513 has excellent I/O
CPU_LOAD_THRESHOLD=60   # Higher threshold due to unified memory access
POOL_HEALTH_CHECK=true
VM_IMPACT_CHECK=true

# CPU topology detection
CORE_COUNT=$(nproc)
MAX_LOAD=$((CORE_COUNT * CPU_LOAD_THRESHOLD / 100))

# NPS1 specific settings
NUMA_MODE="NPS1"
SINGLE_NUMA_DOMAIN=true  # Optimizations for single NUMA domain
L3_CACHE_DOMAINS=8       # EPYC 7513 has 8 CCX domains

check_proxmox_environment() {
    local error_count=0
    local warn_count=0
    
    echo -e "\n${C_BYELLOW}Proxmox Environment Check (EPYC 7513 Optimized)${C_RESET}"
    
    # Check memory usage (NPS1-optimized)
    local mem_used_percent
    mem_used_percent=$(free | grep Mem | awk '{print int($3/$2 * 100)}')
    echo -e "\n${C_BCYAN}Memory Usage:${C_RESET} ${mem_used_percent}%"
    
    # In NPS1 mode, we check overall memory pressure instead of per-NUMA node
    if [ -f "/proc/pressure/memory" ]; then
        # Try to extract avg10, fall back to avg60 or avg300; convert to integer percent
        memory_pressure=0
        memory_label="avg"
        read -r mp_line < /proc/pressure/memory
        if echo "$mp_line" | grep -q "avg10="; then
            memory_label="avg10"
            mp_val=$(echo "$mp_line" | sed -n 's/.*avg10=\([0-9.]*\).*/\1/p')
        elif echo "$mp_line" | grep -q "avg60="; then
            memory_label="avg60"
            mp_val=$(echo "$mp_line" | sed -n 's/.*avg60=\([0-9.]*\).*/\1/p')
        elif echo "$mp_line" | grep -q "avg300="; then
            memory_label="avg300"
            mp_val=$(echo "$mp_line" | sed -n 's/.*avg300=\([0-9.]*\).*/\1/p')
        else
            mp_val=0
        fi
        # Convert decimal string to integer percent (e.g., 0.01 -> 1)
        if [[ "$mp_val" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            memory_pressure=$(printf "%d" "$(awk -v v="$mp_val" 'BEGIN { printf "%f", v*100 }')" 2>/dev/null || printf "%d" 0)
        else
            memory_pressure=0
        fi
        echo -e "${C_BCYAN}Memory Pressure (${memory_label} 10s avg):${C_RESET} ${memory_pressure}%"
        if [ "${memory_pressure:-0}" -gt 50 ]; then
            warn "High memory pressure detected: ${memory_pressure}%"
            ((warn_count++))
        fi
    fi

    # Check CPU cache coherency domains (CCX) for EPYC
    if [ -d "/sys/devices/system/cpu/cpu0/cache/index3" ]; then
        echo -e "${C_BCYAN}L3 Cache Domain Distribution:${C_RESET}"
        # Collect shared_cpu_list files and iterate to show per-CCX CPU lists
        mapfile -t ccx_files < <(find /sys/devices/system/cpu/cpu*/cache/index3 -name shared_cpu_list | sort -V 2>/dev/null)
        if [ ${#ccx_files[@]} -eq 0 ]; then
            echo "  (no CCX cpu lists found)"
        else
            for i in "${!ccx_files[@]}"; do
                cpu_list=$(cat "${ccx_files[$i]}" 2>/dev/null || echo "unknown")
                echo "  CCX $i CPUs: $cpu_list"
            done
        fi
    fi
    
    if [ "${mem_used_percent}" -gt "$MEMORY_THRESHOLD" ]; then
        error "High memory usage detected: ${mem_used_percent}% (threshold: ${MEMORY_THRESHOLD}%)"
        ((error_count++))
    fi
    
    # Check ARC size vs total memory
    if command -v arcstat >/dev/null 2>&1; then
        local arc_size
        arc_size=$(arcstat -s 1 1 | tail -n 1 | awk '{print $2}')
        local total_mem
        total_mem=$(free -b | grep Mem | awk '{print $2}')
        local arc_percent
        arc_percent=0
        if [[ "$arc_size" =~ ^[0-9]+$ ]] && [[ "$total_mem" =~ ^[0-9]+$ ]] && [ "$total_mem" -gt 0 ]; then
            arc_percent=$((arc_size * 100 / total_mem))
        fi
        echo -e "${C_BCYAN}ZFS ARC Usage:${C_RESET} ${arc_percent}%"
        
        if [[ "$arc_percent" =~ ^[0-9]+$ ]] && [ "$arc_percent" -gt 60 ]; then
            warn "ZFS ARC is using ${arc_percent}% of system memory"
            ((warn_count++))
        fi
    fi
    
    # Check IO wait and CPU load (EPYC NPS1-optimized)
    local io_wait
    # Extract IO wait as integer, fallback to 0 if parsing fails
    io_wait=$(top -bn1 | awk -F"," '/Cpu\(s\)/ { for(i=1;i<=NF;i++) if ($i ~ /id/) { split($i,a," "); print int(a[1]) ; exit } }' 2>/dev/null || true)
    # The above gives idle; compute io wait as 100-idle if numeric
    if [[ "$io_wait" =~ ^[0-9]+$ ]]; then
        io_wait=$((100 - io_wait))
    else
        io_wait=0
    fi
    echo -e "${C_BCYAN}IO Wait:${C_RESET} ${io_wait}%"
    
    # Check CPU scheduler domain pressure
    if [ -f "/proc/pressure/cpu" ]; then
        # Extract avg10/avg60/avg300 similar to memory parsing
        cpu_pressure=0
        cpu_label="avg"
        read -r cp_line < /proc/pressure/cpu
        if echo "$cp_line" | grep -q "avg10="; then
            cpu_label="avg10"
            cp_val=$(echo "$cp_line" | sed -n 's/.*avg10=\([0-9.]*\).*/\1/p')
        elif echo "$cp_line" | grep -q "avg60="; then
            cpu_label="avg60"
            cp_val=$(echo "$cp_line" | sed -n 's/.*avg60=\([0-9.]*\).*/\1/p')
        elif echo "$cp_line" | grep -q "avg300="; then
            cpu_label="avg300"
            cp_val=$(echo "$cp_line" | sed -n 's/.*avg300=\([0-9.]*\).*/\1/p')
        else
            cp_val=0
        fi
        if [[ "$cp_val" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            cpu_pressure=$(printf "%d" "$(awk -v v="$cp_val" 'BEGIN { printf "%f", v*100 }')" 2>/dev/null || printf "%d" 0)
        else
            cpu_pressure=0
        fi
        echo -e "${C_BCYAN}CPU Pressure (${cpu_label} 10s avg):${C_RESET} ${cpu_pressure}%"
        if [ "$cpu_pressure" -gt 40 ]; then
            warn "High CPU pressure detected: ${cpu_pressure}%"
            ((warn_count++))
        fi
    fi
    
    # Get per-CCX (Core Complex) CPU usage for EPYC with NPS1
    if command -v mpstat >/dev/null 2>&1; then
        echo -e "${C_BCYAN}CPU Complex Usage (NPS1 mode):${C_RESET}"
        # Group CPUs by L3 cache domain in NPS1 mode
        for ((i=0; i<CORE_COUNT; i+=8)); do
            local ccx_usage
            ccx_usage=$(mpstat -P $i,$(($i+1)),$(($i+2)),$(($i+3)),$(($i+4)),$(($i+5)),$(($i+6)),$(($i+7)) 1 1 | \
                       awk 'END {print 100-$NF}')
            echo "  CCX $((i/8)) usage: ${ccx_usage}%"
            if [ "${ccx_usage%.*}" -gt 85 ]; then
                warn "High CCX $((i/8)) usage: ${ccx_usage}%"
                ((warn_count++))
            fi
        done
    fi
    
    # Check system load average against EPYC core count
    local load_avg
    load_avg=$(cut -d ' ' -f1 /proc/loadavg)
    echo -e "${C_BCYAN}System Load Average:${C_RESET} $load_avg (max recommended: $MAX_LOAD)"
    # Compare as floats using bc only if load_avg is numeric
    if [[ "$load_avg" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        if [ "$(echo "$load_avg > $MAX_LOAD" | bc -l)" -eq 1 ]; then
            error "High system load detected: $load_avg (threshold: $MAX_LOAD)"
            ((error_count++))
        fi
    fi
    
    if [ "${io_wait}" -gt "$IO_WAIT_THRESHOLD" ]; then
        error "High IO wait detected: ${io_wait}% (threshold: ${IO_WAIT_THRESHOLD}%)"
        ((error_count++))
    fi
    
    # Check ZFS pool health
    if [ "$POOL_HEALTH_CHECK" = true ]; then
        echo -e "\n${C_BCYAN}ZFS Pool Health:${C_RESET}"
        while IFS= read -r pool; do
            local health
            health=$(zpool status "$pool" | grep -E "state:" | awk '{print $2}')
            echo -e "  Pool ${C_BMAGENTA}${pool}${C_RESET}: ${health}"
            if [ "$health" != "ONLINE" ]; then
                error "Pool $pool is not healthy (state: $health)"
                ((error_count++))
            fi
            
            # Check pool capacity
            local capacity
            capacity=$(zpool list -H -o capacity "$pool" | tr -d '%')
            echo -e "  Capacity: ${capacity}%"
            if [ "$capacity" -gt 80 ]; then
                warn "Pool $pool usage is high: ${capacity}%"
                ((warn_count++))
            fi
        done < <(zpool list -H -o name)
    fi
    
    # Check running VMs/CTs
    if [ "$VM_IMPACT_CHECK" = true ]; then
        echo -e "\n${C_BCYAN}Active VM/CT Check:${C_RESET}"
        
        # Check QEMU VMs
        local running_vms=0
        running_vms=$(qm list | grep -c "running" || echo "0")
        echo "  Running VMs: $running_vms"
        
        # Check LXC containers
        local running_cts=0
        running_cts=$(pct list | grep -c "running" || echo "0")
        echo "  Running CTs: $running_cts"
        
        # Warning if there are many active instances
        if [ "$running_vms" -gt 0 ] || [ "$running_cts" -gt 0 ]; then
            warn "Active VMs/CTs detected. Changes may impact running instances."
            ((warn_count++))
        fi
    fi
    
    echo -e "\n${C_BCYAN}Summary:${C_RESET}"
    echo "  Errors: $error_count"
    echo "  Warnings: $warn_count"
    
    # Exit if critical issues found
    if [ "$error_count" -gt 0 ]; then
        error "Critical issues detected in Proxmox environment. Use --force to override."
        return 1
    elif [ "$warn_count" -gt 0 ]; then
        warn "Non-critical issues detected. Proceeding with caution."
    fi
    
    return 0
}

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
  --check-resources Display current resource usage and state

Examples:
  $PROG_NAME compression=lz4 oracle/secure*                 
  $PROG_NAME atime=off media -g                             
  $PROG_NAME recordsize=1M '^oracle/secure[0-9]+' -x --dry-run
  $PROG_NAME recordsize=1M '^oracle/secure[0-9]+' -x --im-sure --yes --log /var/log/zfs-sentinel.log
EOF
}

# ---------- Initial validation ----------
check_required_commands
validate_environment

# Proxmox-specific checks
if ! check_proxmox_environment; then
    if [ "${FORCE:-false}" != "true" ]; then
        error "Proxmox environment checks failed. Use --force to override."
        exit 30
    else
        warn "Proceeding despite Proxmox environment warnings (--force)"
    fi
fi

# Set operation timeout
TIMEOUT=${TIMEOUT:-$DEFAULT_TIMEOUT}
if command -v perl >/dev/null 2>&1; then
    perl -e "alarm $TIMEOUT; exec @ARGV" "$0" "$@"
fi

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

# ---------- Arg precheck ----------
if [[ "$1" == -* ]] || [[ "$1" != *=* ]]; then
    echo -e "${C_BRED}Invalid flag or missing property:${C_RESET} $1"
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
        --check-resources)
            check_resources "all" "true"
            exit 0
            ;;
        --force)
            FORCE=true
            ;;
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

# Validate log file permissions if specified
validate_logfile() {
    if [ -n "$LOGFILE" ]; then
        if [ -f "$LOGFILE" ] && ! [ -w "$LOGFILE" ]; then
            echo -e "${C_BRED}Error:${C_RESET} Log file $LOGFILE is not writable." >&2
            exit 14
        fi
        if ! [ -w "$(dirname "$LOGFILE")" ]; then
            echo -e "${C_BRED}Error:${C_RESET} Log directory $(dirname "$LOGFILE") is not writable." >&2
            exit 15
        fi
    fi
}

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
# Use -0 with zfs list to handle datasets with spaces
targets=$(zfs list -H -0 -o name 2>/dev/null || true)
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

# Validate property value
validate_property() {
    # Basic validation - property shouldn't be empty
    if [ -z "$param" ] || [ -z "$val" ]; then
        echo -e "${C_BRED}Error:${C_RESET} Invalid property format. Must be property=value" >&2
        exit 16
    fi

    # Check if property exists (using first matched dataset)
    if ! zfs get -H "$param" "${matched[0]}" >/dev/null 2>&1; then
        echo -e "${C_BRED}Error:${C_RESET} Invalid or non-existent ZFS property: $param" >&2
        exit 17
    fi
}

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
