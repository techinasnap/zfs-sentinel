# zfs-sentinel — Bulk changes with operator safety

I built zfs-sentinel to safely apply ZFS property changes across many datasets when built‑in options aren’t enough. It defaults to a dry‑run preview, highlights planned changes, displays a high‑visibility warning banner, and offers audit logging and automation flags for CI and scripted workflows.

---

## Why this exists

- Prevent mistakes: Dry-run first, confirmation required unless explicitly skipped.
- See everything: Color-coded param=value, alternating dataset names, and a high-visibility warning banner.
- Automate safely: Flags for no-color, no-clear, and non-interactive runs that won’t wreck your terminal or logs.
- Audit-friendly: Optional logging of applied changes with timestamps and dataset lists.

---

## Features

- Dry-run by default; explicit `--dry-run` overrides `--im-sure` if both are present
- Param/value highlighting for quick visual parsing
- Dataset preview with alternating colors and wide layout
- Warning banner always shown before action
- Spinner/progress during live runs
- Invalid flag detection with clear breadcrumbs
- Debug mode to echo parsed configuration and matched datasets
- Automation flags: `--yes`, `--no-color`, `--no-clear`
- Audit logs: `--log <file>`

---

## Installation

```bash
# Clone and install
git clone https://github.com/meabert/zfs-bulk.git
cd zfs-bulk
sudo install -m 0755 zfs-bulk /usr/local/bin/zfs-bulk
```

# Or run in place

```bash
chmod +x zfs-bulk
./zfs-bulk -h
```

# If you want to make it globally available:

```bash
sudo install -m 0755 zfs-bulk /usr/local/bin/zfs-bulk
```

## Preview changes across a set of datasets (dry-run)
```bash 
zfs-bulk compression=lz4 pool/app/*
```

## Apply for real (interactive confirmation)
```bash 
zfs-bulk canmount=on pool/app/* --im-sure
```

## Non-interactive automation, no color, no clear, logs to file
```bash
zfs-bulk atime=off pool/app/* --im-sure --yes --no-color --no-clear --log /var/log/zfs-bulk.log
```

## Usage
```bash
zfs-bulk <property=value> <pattern> [options]
```
- property=value: ZFS property assignment (e.g., compression=lz4, atime=off, recordsize=1M)

- pattern: dataset selector; supports glob, grep, or regex (see flags)

## Matching modes

- default (glob): shell-style match pool/ds/*

- -g, --grep: plain substring match

- -x, --regex: extended regex via [[ =~ ]]

## Flags

- -h, --help: Show help and examples

- --dry-run: Force dry-run mode (overrides --im-sure if both given)

- --im-sure: Perform the live operation

- --yes: Skip confirmation (use with care; for automation)

- --log <file>: Append a timestamped audit entry and dataset list

- --no-color: Disable ANSI colors (plain text output)

- --no-clear: Don’t clear the screen before live confirmation

- --debug: Print parsed configuration, matched datasets, and counts

Invalid flags trigger an immediate breadcrumb: “Invalid flag --whatever. Please use -h or --help for more info.”

Safety notes
ZFS properties can change IO behavior, durability, and performance characteristics. Know the implications before applying changes.

Always start with a dry-run and examine the preview and warning banner.

Consider staging changes (e.g., test datasets first) before bulk operations on production.

Color palette
The script includes a unified ANSI palette (bold, backgrounds) and uses:

Parameters: bold magenta

Values: bold green

Dataset preview: alternating bold cyan/yellow

Warnings: yellow background with black text

Use --no-color for CI or plain logs.

Logging
Enable with --log <file>:

Appends timestamp, property, count, and dataset list

Plain text; no ANSI codes

Example:

bash
zfs-bulk compression=lz4 pool/app/* --im-sure --yes --log /var/log/zfs-bulk.log
Contributing
Issues and PRs welcome. Please include:

Repro steps

Expected vs. actual behavior

Environment details (OS, ZFS version)

Ideas:

Unit tests via bats-core

Dry-run diff mode (“show current vs. target property”)

CSV/JSON export of matched datasets and results

## License

This project is licensed under the [MIT License](./LICENSE).
