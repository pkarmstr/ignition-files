#!/bin/bash

set -euo pipefail

# Pinned for reproducibility; override with the BUTANE_IMAGE env var if needed.
BUTANE_IMAGE="${BUTANE_IMAGE:-quay.io/coreos/butane:v0.29.0}"

usage() {
  cat <<EOF
Usage: $0 [butane-args...] <input.bu> <output.ign>

Transpiles a Butane (.bu) file into an Ignition (.ign) file using the butane
container image (default: $BUTANE_IMAGE; override with the BUTANE_IMAGE
environment variable).

All arguments before the input/output files are passed through to butane.
'--strict' is added automatically unless you already pass it.
'--files-dir' is managed by this script: it is set to the input file's
directory, so 'local:' references in the .bu resolve relative to the .bu
file. Do not pass --files-dir yourself.

The working directory is mounted into the container read-only, so the input
path must be relative to the working directory (no absolute paths, no '..').

Examples:
  $0 config.bu config.ign
  $0 --pretty config.bu config.ign
EOF
  exit 1
}

if ! command -v docker >/dev/null 2>&1; then
  echo "Error: 'docker' not found in PATH." >&2
  echo "Install docker (or provide a 'docker' shim, e.g. 'podman docker') and try again." >&2
  exit 1
fi

# Need at least 2 args (input + output)
if [ $# -lt 2 ]; then
  usage
fi

# Last two args are input and output files
OUTPUT_FILE="${@: -1}"
INPUT_FILE="${@: -2:1}"
BUTANE_ARGS=("${@:1:$(($#-2))}")

# The input is mounted at /cwd/<INPUT_FILE>, so reject paths that break
# that mapping: absolute paths and path traversal.
case "$INPUT_FILE" in
  /*)
    echo "Error: input path '$INPUT_FILE' must be relative to the working directory." >&2
    exit 1
    ;;
  .. | ../* | */.. | */../*)
    echo "Error: input path '$INPUT_FILE' must not contain '..'." >&2
    exit 1
    ;;
esac

# Check input exists
if [ ! -f "$INPUT_FILE" ]; then
  echo "Error: Input file '$INPUT_FILE' not found." >&2
  exit 1
fi

# '--strict' is recommended; add it unless the user already passed it.
strict=0
for arg in "${BUTANE_ARGS[@]}"; do
  if [ "$arg" = "--strict" ]; then
    strict=1
    break
  fi
done
if [ "$strict" -eq 0 ]; then
  BUTANE_ARGS+=("--strict")
fi

# 'local:' references resolve relative to the .bu file's directory.
INPUT_DIR="$(dirname "$INPUT_FILE")"

echo "Transpiling '$INPUT_FILE' into '$OUTPUT_FILE'..."
echo "Image: $BUTANE_IMAGE"
echo "Args: ${BUTANE_ARGS[*]:-<none>} --files-dir /cwd/$INPUT_DIR"

# Write to a temp file first so a failed run never leaves a truncated/empty
# .ign behind.
TMP_OUT="$(mktemp)"
trap 'rm -f "$TMP_OUT"' EXIT

if ! docker run --rm -v "$(pwd):/cwd:ro" "$BUTANE_IMAGE" \
    "${BUTANE_ARGS[@]}" --files-dir "/cwd/$INPUT_DIR" "/cwd/$INPUT_FILE" > "$TMP_OUT"; then
  echo "Error: butane transpilation failed (see docker output above)." >&2
  exit 1
fi

# Validate the output before replacing any existing .ign file.
if [ ! -s "$TMP_OUT" ]; then
  echo "Error: butane produced empty output; not writing '$OUTPUT_FILE'." >&2
  exit 1
fi
if command -v jq >/dev/null 2>&1; then
  if ! jq -e . "$TMP_OUT" >/dev/null 2>&1; then
    echo "Error: butane output is not valid JSON; not writing '$OUTPUT_FILE'." >&2
    exit 1
  fi
elif command -v python3 >/dev/null 2>&1; then
  if ! python3 -m json.tool "$TMP_OUT" >/dev/null 2>&1; then
    echo "Error: butane output is not valid JSON; not writing '$OUTPUT_FILE'." >&2
    exit 1
  fi
else
  echo "Warning: neither 'jq' nor 'python3' found; skipping JSON validation." >&2
fi

mv "$TMP_OUT" "$OUTPUT_FILE"
echo "Success! Saved to '$OUTPUT_FILE'."
