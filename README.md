# zfs-sentinel — Safe, auditable sentinel ZFS property management

A compact CLI that safely applies ZFS property changes across many datasets. Dry-run by default, operator-guarded for live runs, and audit-ready for CI and compliance.

## Quick highlights
+ **Default safety:** Dry-run preview unless explicitly confirmed with ``--im-sure``.

+ **Triple-lock approval:** dry-run, token-based approval for sensitive properties, and typed interactive confirmation in a TTY.

+ **Flexible selection:** glob, substring grep ``--grep``, or extended regex ``--regex`` matching.

+ **Audit-ready:** append-only structured logs including timestamp, UID, PID, and dataset list.

+ **Automation-friendly:** ``--dry-run``, ``--yes``, ``--no-color``, ``--no-clear``, and ``--log`` <file> for headless or CI environments.

+ **Operator UX:** colorized param/value preview, high-visibility warning banner, ``--debug`` mode, and non-fatal per-dataset error handling.

+ **Resource monitoring:** comprehensive system resource tracking, cleanup management, and environment validation.

+ **Proxmox optimized:** specific checks for VM impact, ZFS ARC usage, and pool health.

+ **EPYC hardware aware:** optimized for AMD EPYC processors with CCX and NUMA awareness.

## Prerequisites
+ **Platform:** Linux distributions with ZFS on Linux / OpenZFS installed and a POSIX shell.

+ **Commands required:** ``zfs``, ``zpool``, ``sh``, ``mkdir``, ``chmod``, ``chown``, ``date``, ``tput``, ``sed``, ``cut``, ``head``, ``base64``, ``printf``, ``read``.

+ **Shell:** Bash 4.4 or newer for array handling and robust string features.

+ **Privileges:** Root or a user with sufficient privileges to run zfs/zpool operations and write to system locations used for logging and token storage.

# Installation

## Clone the repo:
```bash
git clone https://github.com/meabert/zfs-sentinel.git
cd zfs-sentinel
```
## Install for global availability:
```bash
sudo install -m 0755 zfs-sentinel /usr/local/bin/zfs-sentinel
```
**OR**
## Run in place for portability:
```bash
chmod +x zfs-sentinel
./zfs-sentinel -h
```
# Usage
```bash
zfs-sentinel <property=value> <pattern> [options]
```
+ **property=value:** ZFS property assignment (e.g., compression=lz4, atime=off, recordsize=1M)

+ **pattern:** dataset selector; supports glob, grep, or regex (see flags)

## Preview changes across a set of datasets (dry-run):
```bash 
zfs-sentinel compression=lz4 pool/app/*
```
## Apply for real (interactive confirmation):
```bash 
zfs-sentinel canmount=on pool/app/* --im-sure
```
## Non-interactive automation, no color, no clear, logs to file:
```bash
zfs-sentinel atime=off pool/app/* --im-sure --yes --no-color --no-clear --log /var/log/zfs-sentinel.log
```

# Flags

+ ``-h``, ``--help``: Show help and examples

+ ``--dry-run``: Force dry-run mode (overrides ``--im-sure`` if both given)

+ ``--im-sure``: Perform the live operation

+ ``--yes``: Skip confirmation (use with care; for automation)

+ ``--log <file>``: Append a timestamped audit entry and dataset list

+ ``--no-color``: Disable ANSI colors (plain text output)

+ ``--no-clear``: Don't clear the screen before live confirmation

+ ``--debug``: Print parsed configuration, matched datasets, and counts

+ ``--check-resources``: Display detailed system resource usage and state

+ ``--force``: Override resource check warnings (use with extreme caution)

+ Invalid flags trigger an immediate breadcrumb: "Invalid flag ``--whatever``. Please use ``-h`` or ``--help`` for more info."

# Resource Monitoring

The script includes comprehensive resource monitoring optimized for server environments:

## General Resources
+ Memory usage and pressure monitoring
+ I/O wait and system load tracking
+ Background process management
+ Temporary file tracking and cleanup
+ Lock file management

## Proxmox-Specific Features
+ VM and Container impact analysis
+ ZFS ARC usage monitoring
+ Pool health verification
+ Resource pressure detection

## EPYC 7513 Optimizations
+ NPS1 mode awareness
+ CCX (Core Complex) usage monitoring
+ L3 cache domain distribution
+ Unified memory pressure tracking

## Default Thresholds (EPYC 7513 NPS1)
+ Memory usage: 94%
+ I/O wait: 15%
+ CPU load: 60% per core
+ Memory pressure warning: 50%
+ CPU pressure warning: 40%
+ CCX usage warning: 85%

These thresholds are optimized for:
+ 32-core/64-thread EPYC 7513
+ NPS1 NUMA configuration
+ ZFS workloads
+ VM hosting environments

# Adjusting Thresholds

The default thresholds are optimized for an EPYC 7513 server in NPS1 mode. Here are recommended adjustments for different hardware profiles:

## Desktop Workstation
```bash
MEMORY_THRESHOLD=85     # More conservative for desktop use
IO_WAIT_THRESHOLD=25    # Higher threshold for consumer storage
CPU_LOAD_THRESHOLD=40   # Lower to maintain desktop responsiveness
L3_CACHE_DOMAINS=2      # Typical for consumer CPUs
```

## Laptop
```bash
MEMORY_THRESHOLD=80     # Conservative for mobile devices
IO_WAIT_THRESHOLD=30    # Higher for mobile storage
CPU_LOAD_THRESHOLD=30   # Lower for battery life
SINGLE_NUMA_DOMAIN=true # Most laptops are single NUMA
```

## High-Performance Workstation (e.g., Threadripper)
```bash
MEMORY_THRESHOLD=90     # Balance of performance and safety
IO_WAIT_THRESHOLD=20    # Moderate for HEDT storage
CPU_LOAD_THRESHOLD=50   # Balanced for high core count
L3_CACHE_DOMAINS=4      # Adjust based on CPU model
```

## Virtual Machine / Cloud Instance
```bash
MEMORY_THRESHOLD=88     # Conservative for shared resources
IO_WAIT_THRESHOLD=40    # Higher for virtualized storage
CPU_LOAD_THRESHOLD=35   # Conservative for shared CPU
SINGLE_NUMA_DOMAIN=true # Unless using large instances
```

## Low-Resource System
```bash
MEMORY_THRESHOLD=75     # Very conservative
IO_WAIT_THRESHOLD=45    # Higher for slower storage
CPU_LOAD_THRESHOLD=25   # Prioritize system responsiveness
VM_IMPACT_CHECK=false   # Disable if not using VMs
```

## Factors to Consider When Adjusting:

1. **Memory Threshold**
   - Lower for systems with active desktop environments
   - Higher for dedicated servers
   - Consider available swap space
   - Account for ZFS ARC size

2. **I/O Wait Threshold**
   - Lower for NVMe/SSD storage
   - Higher for HDDs or network storage
   - Consider RAID/ZFS configuration
   - Account for backup schedules

3. **CPU Load Threshold**
   - Scale with core count
   - Lower for interactive systems
   - Higher for dedicated servers
   - Consider thermal constraints

4. **Cache Domains**
   - Match CPU topology
   - Consider NUMA configuration
   - Align with core complexes
   - Account for SMT/HT

To modify these thresholds, edit the script and adjust the values in the "Proxmox Environment Checks" section.

# Resource Management
The script implements robust resource management:

## Cleanup Handling
+ Automatic temporary file cleanup
+ Background process termination
+ Lock file removal
+ PID file management

## Resource Tracking
+ Active process monitoring
+ File descriptor tracking
+ Memory allocation tracking
+ System pressure monitoring

## Safety Measures
+ Pre-operation resource verification
+ Post-operation cleanup
+ Interrupt handling
+ Timeout management

## Matching modes

+ default (glob): shell-style match pool/ds/*

+ ``-g``, ``--grep``: plain substring match

+ ``-x``, ``--regex``: extended regex via [[ =~ ]]

# Safety notes
+ ZFS properties can change IO behavior, durability, and performance characteristics. Know the implications before applying changes.

+ Always start with a dry-run and examine the preview and warning banner.

+ Consider staging changes (e.g., test datasets first) before sentinel operations on production.

# Color palette
+ The script includes a unified ANSI palette (bold, backgrounds) and uses:

+ Parameters: bold magenta
 
+ Values: bold green

+ Dataset preview: alternating bold cyan/yellow

+ Warnings: yellow background with black text

+ Use ``--no-color`` for CI or plain logs.

# Logging
+ Enable with ``--log <file>``:

+ Appends timestamp, property, count, and dataset list

+ Plain text; no ANSI codes

# Example:

```bash
zfs-sentinel compression=lz4 pool/app/* --im-sure --yes --log /var/log/zfs-sentinel.log
```
# Error Codes

The script uses the following error codes for diagnostics:

+ `1`: Invalid flag or missing property
+ `2`: Missing log file path
+ `3`: Invalid flag
+ `4`: Unexpected extra argument
+ `5`: Missing dataset pattern
+ `6`: No ZFS datasets found
+ `7`: No datasets matched pattern
+ `8`: Dataset validation failed
+ `9`: Missing token file for sensitive property
+ `10`: Empty token file
+ `11`: Token mismatch
+ `12`: User aborted operation
+ `13`: Confirmation mismatch
+ `14`: Log file not writable
+ `15`: Log directory not writable
+ `16`: Invalid property format
+ `17`: Invalid or non-existent ZFS property

# Troubleshooting

Common issues and solutions:

1. **Permission Denied**
   - Ensure you have sufficient privileges (root or proper sudo access)
   - Check file permissions on log directory
   - Verify token file permissions

2. **No Datasets Found**
   - Verify ZFS is properly installed and running
   - Check if pools are imported
   - Confirm user has permission to list datasets

3. **Pattern Matching Issues**
   - Test pattern with `--debug` flag
   - Try different matching modes (grep/regex)
   - Check for special characters in dataset names

4. **Token Validation Fails**
   - Verify token file exists at `/etc/zfs-sentinel/confirm.token`
   - Check token file permissions
   - Ensure token value matches exactly

5. **Log File Issues**
   - Check directory permissions
   - Verify disk space
   - Ensure log rotation is configured if needed

# Security Considerations

1. **Token Management**
   - Regularly rotate confirmation tokens
   - Restrict token file access to authorized users
   - Use secure permissions (600) on token file

2. **Logging**
   - Configure log rotation to prevent disk space issues
   - Protect log files with appropriate permissions
   - Monitor log files for unauthorized access attempts

3. **Access Control**
   - Limit script access to authorized operators
   - Use sudo rules to restrict property modifications
   - Audit all changes via log files

# Contributing
Issues and PRs welcome. Please include:

+ Steps to reproduce

+ Expected vs. actual behavior

+ Environment details (OS, ZFS version)

+ Debug logs

Ideas:

+ Parameter key with built in logic to throw exceptions on read-only and creation-only values (i.e. case sensitivity)

+ Unit tests via bats-core

+ Dry-run diff mode (“show current vs. target property”)

+ CSV/JSON export of matched datasets and results

## License

This project is licensed under the [MIT License](./LICENSE).
