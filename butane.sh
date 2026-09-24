#!/bin/bash

set -euo pipefail

# Pinned for reproducibility; override with the BUTANE_IMAGE env var if needed.
BUTANE_IMAGE="${BUTANE_IMAGE:-quay.io/coreos/butane:v0.29.0}"

BUILD_DIR="builds"

usage() {
  cat <<EOF
Usage: $0 [butane-args...] <machine-dir>

Transpiles <machine-dir>/config.bu into $BUILD_DIR/<machine-dir>.ign using the
butane container image (default: $BUTANE_IMAGE; override with the BUTANE_IMAGE
environment variable).

All arguments before the machine directory are passed through to butane.
'--strict' is added automatically unless you already pass it.

The password hash (\${USER_PASSWORD_HASH}) is the only secret not committed
in the .bu: it is read from a gitignored 'secrets.env' in the machine
directory and substituted into a temp copy before transpiling. SSH public
keys are public by definition and live in git: canonical copies in keys/,
inlined in each .bu's ssh_authorized_keys (butane has no file reference for
that field).
'--files-dir' is managed by this script: it is set to the repo root
(the working directory), so 'local:' references in the .bu resolve
relative to it — machine files as '<machine-dir>/<name>', files shared
by several machines as 'shared/<name>'.
Do not pass --files-dir yourself.

The working directory is mounted into the container read-only, so the
machine directory must be relative to the working directory
(no absolute paths, no '..').

Examples:
  $0 nevua-ketana
  $0 --pretty nevua-ketana
EOF
  exit 1
}

if ! command -v docker >/dev/null 2>&1; then
  echo "Error: 'docker' not found in PATH." >&2
  echo "Install docker (or provide a 'docker' shim, e.g. 'podman docker') and try again."
  exit 1
fi

# Need at least 1 arg (machine dir)
if [ $# -lt 1 ]; then
  usage
fi

# Last arg is the machine directory; everything before it goes to butane.
MACHINE_DIR="${@: -1}"
BUTANE_ARGS=("${@:1:$(($#-1))}")

# The machine dir is mounted at /cwd/<MACHINE_DIR>, so reject paths that
# break that mapping: absolute paths and path traversal.
case "$MACHINE_DIR" in
  /*)
    echo "Error: machine dir '$MACHINE_DIR' must be relative to the working directory." >&2
    exit 1
    ;;
  .. | ../* | */.. | */../*)
    echo "Error: machine dir '$MACHINE_DIR' must not contain '..'." >&2
    exit 1
    ;;
esac

if [ ! -d "$MACHINE_DIR" ]; then
  echo "Error: machine dir '$MACHINE_DIR' not found." >&2
  exit 1
fi

INPUT_FILE="$MACHINE_DIR/config.bu"
OUTPUT_FILE="$BUILD_DIR/${MACHINE_DIR%/}.ign"
if [ ! -f "$INPUT_FILE" ]; then
  echo "Error: '$INPUT_FILE' not found. Each machine dir needs a config.bu." >&2
  exit 1
fi

# Secrets are substituted into a temp copy of the .bu so the committed file
# never contains them. The copy lives next to the original so 'local:' file
# references (resolved via --files-dir) still resolve.
SECRETS_FILE="$MACHINE_DIR/secrets.env"
if [ ! -f "$SECRETS_FILE" ]; then
  echo "Error: secrets file '$SECRETS_FILE' not found." >&2
  echo "Create it with USER_PASSWORD_HASH (see README)." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$SECRETS_FILE"

# envsubst is a subprocess, so the values must be exported, not just set.
SECRETS_VARS='USER_PASSWORD_HASH'
for var in $SECRETS_VARS; do
  if [ -z "${!var:-}" ]; then
    echo "Error: '$var' is missing or empty in '$SECRETS_FILE'." >&2
    exit 1
  fi
  export "$var"
done

TMP_BU="$MACHINE_DIR/.config.bu.resolved"
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

mkdir -p "$BUILD_DIR"
echo "Transpiling '$INPUT_FILE' into '$OUTPUT_FILE'..."
echo "Image: $BUTANE_IMAGE"
echo "Args: ${BUTANE_ARGS[*]:-<none>} --files-dir /cwd"

# Write to a temp file first so a failed run never leaves a truncated/empty
# .ign behind.
if ! docker run --rm -v "$(pwd):/cwd:ro" "$BUTANE_IMAGE" \
    "${BUTANE_ARGS[@]}" --files-dir /cwd "/cwd/$TMP_BU" > "$TMP_OUT"; then
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
