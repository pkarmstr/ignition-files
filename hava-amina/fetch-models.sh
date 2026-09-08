#!/bin/bash
#
# hava-amina: put the llama.cpp model files onto the storage volume.
#
# The volume comes out of Ignition (storage.filesystems in the .bu) empty, and
# a 24 GB GGUF is far too large to embed in an Ignition config, so it is
# fetched over the LAN. Run once by fetch-models.service, after the rebase
# chain completes.
#
# The server side is a plain python http.server on erevrav (192.168.0.24)
# serving the shared model library
# (/mnt/storage/nevua-ketana-backup/20tb-hdd/llama-models), so one path string
# is both the URL suffix and the destination suffix:
#
#   python3 -m http.server 33334 \
#     --directory /mnt/storage/nevua-ketana-backup/20tb-hdd/llama-models
#
# Only the model this machine actually serves is fetched here — one
# ~24 GB GGUF, its chat template and the router's preset INI. When the
# strix box's full library is restored it is the same directory mapping, one
# rsync:
#
#   rsync -aHAXx --info=progress2 \
#     <strix-box>:/path/to/llama-models/ \
#     keelan@192.168.0.46:/var/mnt/storage/llama-models/
#
# Every file is fetched unconditionally, straight over whatever is at the
# destination. This runs once, on a volume that was just formatted, and
# fetch-models.service does not set its marker unless this script exits 0, so a
# failed run is fixed by running it again, not by comparing lengths.
#
# http.server does not implement Range requests, so a broken transfer cannot be
# resumed: each curl retry, and each re-run of this script after a failure,
# starts that file over from byte 0.
#
set -euo pipefail

BASE_URL="http://192.168.0.24:33334"
MNT_POINT="/var/mnt/storage"          # must match var-mnt-storage.mount's Where=
DEST_ROOT="$MNT_POINT/llama-models"   # bind-mounted as /models in llama-server.container
OWNER="keelan"

# Paths relative to the served directory. The model paths inside
# llama-server-config.ini are these same paths with /models in front, and the
# INI is itself fetched into the tree: that directory is the whole input to the
# server, which is why nothing is seeded into /etc.
FILES=(
  "Qwen-Fixed-Chat-Templates/chat_template.jinja"
  "Qwen3.8-27B-GGUF/Qwen3.8-27B-UD-Q6_K_XL.gguf"
)

[ "$EUID" -eq 0 ] || { echo "Please run as root (sudo)." >&2; exit 1; }

# uid/gid looked up, never hardcoded.
OWNER_UID=$(id -u "$OWNER")
OWNER_GID=$(id -g "$OWNER")

# The tree itself, not only its contents: llama-server-config.ini lives at its
# root and $OWNER edits that file without sudo, so the directory has to belong
# to $OWNER as well. install -d inside the loop chowns only the directory it is
# given, and the parents it creates on the way there land as root.
install -d -o "$OWNER_UID" -g "$OWNER_GID" "$DEST_ROOT"

# The preset INI is served from a machine-scoped subdirectory — the tree root's
# llama-server-config.ini is nevua-ketana's — but installed at the tree root,
# where the container's --models-preset reads it.
echo "Fetching llama-server-config.ini from $BASE_URL/hava-amina/..."
curl --fail --location --silent --show-error \
     --retry 5 --retry-delay 10 --retry-all-errors \
     --output "$DEST_ROOT/llama-server-config.ini" \
     "$BASE_URL/hava-amina/llama-server-config.ini"

chown "$OWNER_UID:$OWNER_GID" "$DEST_ROOT/llama-server-config.ini"
echo "Installed $DEST_ROOT/llama-server-config.ini"

for rel_path in "${FILES[@]}"; do
    dest="$DEST_ROOT/$rel_path"
    # install -d: mkdir -p that also hands the new directory to $OWNER, so
    # nothing on the volume is left owned by root.
    install -d -o "$OWNER_UID" -g "$OWNER_GID" "$(dirname "$dest")"

    echo "Fetching $rel_path from $BASE_URL..."
    # -f makes a 404 from http.server a failure; --retry-all-errors also retries
    # a truncated body, which is how a server that dies mid-transfer shows up.
    curl --fail --location --silent --show-error \
         --retry 5 --retry-delay 10 --retry-all-errors \
         --output "$dest" "$BASE_URL/$rel_path"

    chown "$OWNER_UID:$OWNER_GID" "$dest"
    echo "Installed $dest"
done

echo "Success! Model files are in $DEST_ROOT"
ls -lR "$DEST_ROOT"
