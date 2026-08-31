#!/bin/bash
#
# The two HTTP servers a nevua-ketana install needs from this machine, in one
# foreground command: Ctrl+C stops both. Run it in a tmux pane and leave it up
# for the whole install — see "Installing onto a machine" in README.md.
#
set -u

IGNITION_DIR="/mnt/storage/ignition-files"
MODELS_DIR="/mnt/storage/nevua-ketana-backup/20tb-hdd/llama-models"

# One server in the foreground, one in the background, and the trap reaps the
# background one. Two background servers + `wait` does not work: a bash without
# job control gives background jobs SIGINT *ignored*, so Ctrl+C would stop
# nothing and the script would sit in `wait` forever (a trapped `wait` is not
# interrupted until the command it waits for finishes).
python3 -m http.server 33334 --directory "$MODELS_DIR" &
models_pid="$!"
trap 'kill "$models_pid" 2>/dev/null' EXIT INT TERM

echo "  :33333  $IGNITION_DIR  (the .ign — fetched by coreos-installer)"
echo "  :33334  $MODELS_DIR  (the models — fetched by fetch-models.service)"
echo "Ctrl+C stops both."

# Foreground on purpose: this one is the command, its own SIGINT handler is what
# ends the script (which then fires the EXIT trap above).
python3 -m http.server 33333 --directory "$IGNITION_DIR"
