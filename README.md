# zfs-sentinel — Safe, auditable sentinel ZFS property management

A compact CLI that safely applies ZFS property changes across many datasets. Dry-run by default, operator-guarded for live runs, and audit-ready for CI and compliance.

## Quick highlights
+ **Default safety:** Dry-run preview unless explicitly confirmed with ``--im-sure``.

+ **Triple-lock approval:** dry-run, token-based approval for sensitive properties, and typed interactive confirmation in a TTY.

+ **Flexible selection:** glob, substring grep ``--grep``, or extended regex ``--regex`` matching.

+ **Audit-ready:** append-only structured logs including timestamp, UID, PID, and dataset list.

+ **Automation-friendly:** ``--dry-run``, ``--yes``, ``--no-color``, ``--no-clear``, and ``--log`` <file> for headless or CI environments.

+ **Operator UX:** colorized param/value preview, high-visibility warning banner, ``--debug`` mode, and non-fatal per-dataset error handling.

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
sudo install -m 0755 zfs-sentinel.sh /usr/local/bin/zfs-sentinel
```
**OR**
## Run in place for portability:
```bash
mv zfs-sentinel.sh zfs-sentinel
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
