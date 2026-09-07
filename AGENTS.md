# AGENTS.md

This repo holds custom Butane configs for my personal hardware, so I get simple,
stable, reproducible builds with Fedora CoreOS.

One folder per machine (`nevua-ketana/`, `hava-amina/`) holds the `.bu`, its
embedded helper files, a gitignored `secrets.env`, and the machine's
`HARDWARE.md` (stable drive identifiers). `README.md` documents the boot
sequence, file layout, and Ignition behavior. Read those before changing
anything; keep this file short and non-overlapping with them.

## Guiding principles

The workflow always starts from a fresh install. Don't handle piles of edge
cases. At each step of the build, ask: "what does the machine look like here,
and how do I make that reproducible and stable?" Aim for simplicity and
customization over generality.

Never compute disk IDs, sizes, or sector sizes at runtime. Hard-code them —
"we know this drive has this ID and this sector size" — from the machine's `HARDWARE.md`. A
script that discovers its own target disks fails silently on different
hardware; a script that names the disks fails loudly.

## Build

```bash
./butane.sh nevua-ketana/nevua-ketana.bu nevua-ketana/nevua-ketana.ign    # --strict is added automatically
```

`.ign` files are generated artifacts (gitignored) — never hand-edit them, edit
the `.bu` and re-run the command. Rebuild after any `.bu` or embedded-file
change so the artifact in the tree isn't stale.

## Naming

Everything is **kebab-case**: repo files, installed paths, systemd units, marker
files. A file embedded via `local:` keeps the exact name it has on the machine
(`setup-storage.sh` in the repo, `/usr/local/bin/setup-storage.sh` at runtime),
so one grep finds every reference. This matches systemd's own convention, and
path-derived unit names (`var-mnt-storage.mount`) are kebab-case whether you
want them to be or not.

## Style

Keep bash scripts as simple as possible. A human has to read and debug them
when something goes wrong.

Comments should only explain what a non-obvious command is doing. Don't write
comments about the history of the project or why a previous iteration of a
script failed.

Commit messages are a short one-sentence summary of the change, lowercase, no
conventional-commit prefixes.

## Don't test the toolchain

Don't verify that Butane compiles correctly or that files get embedded/gzipped
properly into the final output. The tool is stable and consistently produces
good output. Be suspicious only when a fresh install fails without explanation.

## Machines

`nevua-ketana` is assigned `192.168.0.45`, `hava-amina` `192.168.0.46`
(the AMD box, no NVIDIA). If an install fails, SSH in as
`keelan` to see what happened, inspect logs, and run tests.

The data-disk scripts are destructive: `setup-storage.sh` wipes both data disks
and `teardown-storage.sh` destroys the volume. Only run them deliberately, and
never against a machine you weren't asked to reprovision.
