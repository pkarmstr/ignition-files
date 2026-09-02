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

Secrets (\${USER_PASSWORD_HASH}, \${USER_SSH_PUBLIC_KEY}) are not committed in
the .bu: they are read from a gitignored 'secrets.env' in the .bu's directory
and substituted into a temp copy before transpiling.
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

# Secrets are substituted into a temp copy of the .bu so the committed file
# never contains them. The copy lives next to the original so 'local:' file
# references (resolved via --files-dir) still resolve.
INPUT_DIR="$(dirname "$INPUT_FILE")"
SECRETS_FILE="$INPUT_DIR/secrets.env"
if [ ! -f "$SECRETS_FILE" ]; then
  echo "Error: secrets file '$SECRETS_FILE' not found." >&2
  echo "Create it with USER_PASSWORD_HASH and USER_SSH_PUBLIC_KEY (see README)." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$SECRETS_FILE"

# envsubst is a subprocess, so the values must be exported, not just set.
SECRETS_VARS='USER_PASSWORD_HASH USER_SSH_PUBLIC_KEY'
for var in $SECRETS_VARS; do
  if [ -z "${!var:-}" ]; then
    echo "Error: '$var' is missing or empty in '$SECRETS_FILE'." >&2
    exit 1
  fi
  export "$var"
done

TMP_BU="$INPUT_DIR/.${INPUT_FILE##*/}.resolved"
TMP_OUT="$(mktemp)"
trap 'rm -f "$TMP_OUT" "$TMP_BU"' EXIT

# Restrict substitution to the secret variables: a bare envsubst would also
# expand things like $IFACE inside the embedded scripts.
SUPPORTED_SUBS="$(printf '\$%s ' $SECRETS_VARS)"
envsubst "$SUPPORTED_SUBS" < "$INPUT_FILE" > "$TMP_BU"
if unresolved=$(grep -nE '\$\{[A-Z_]+\}' "$TMP_BU"); then
  echo "Error: unresolved secret placeholders in '$INPUT_FILE' after substitution:" >&2
  echo "$unresolved" >&2
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

echo "Transpiling '$INPUT_FILE' into '$OUTPUT_FILE'..."
echo "Image: $BUTANE_IMAGE"
echo "Args: ${BUTANE_ARGS[*]:-<none>} --files-dir /cwd/$INPUT_DIR"

# Write to a temp file first so a failed run never leaves a truncated/empty
# .ign behind.
if ! docker run --rm -v "$(pwd):/cwd:ro" "$BUTANE_IMAGE" \
    "${BUTANE_ARGS[@]}" --files-dir "/cwd/$INPUT_DIR" "/cwd/$TMP_BU" > "$TMP_OUT"; then
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
