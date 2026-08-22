#!/bin/bash

set -euo pipefail

BUTANE_IMAGE="${BUTANE_IMAGE:-quay.io/coreos/butane:latest}"

usage() {
  echo "Usage: $0 [butane-args...] <input.bu> <output.ign>"
  echo ""
  echo "All arguments are passed through to the butane transpiler."
  echo "The working directory is mounted into the container so that"
  echo "'local:' file references resolve correctly."
  echo ""
  echo "Examples:"
  echo "  $0 config.bu config.ign"
  echo "  $0 --strict config.bu config.ign"
  echo "  $0 --files-dir ./extras config.bu config.ign"
  exit 1
}

# Need at least 2 args (input + output)
if [ $# -lt 2 ]; then
  usage
fi

# Last two args are input and output files
OUTPUT_FILE="${@: -1}"
INPUT_FILE="${@: -2:1}"
BUTANE_ARGS=("${@:1:$(($#-2))}")

# Check input exists
if [ ! -f "$INPUT_FILE" ]; then
  echo "Error: Input file '$INPUT_FILE' not found." >&2
  exit 1
fi

echo "Transpiling '$INPUT_FILE' into '$OUTPUT_FILE'..."
echo "Args: ${BUTANE_ARGS[*]:-<none>}"

# Mount CWD so 'local:' file refs resolve relative to the .bu file
docker run --rm -v "$(pwd):/cwd:ro" "$BUTANE_IMAGE" \
  "${BUTANE_ARGS[@]}" /cwd/"$INPUT_FILE" > "$OUTPUT_FILE"

echo "Success! Saved to '$OUTPUT_FILE'."
