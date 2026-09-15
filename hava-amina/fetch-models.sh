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
# serving the shared model library:
#
#   python3 -m http.server 33334 \
#     --directory /mnt/storage/nevua-ketana-backup/20tb-hdd/llama-models
#
# The served tree is flat: one directory per model family at its root, and the
# llama-server-config.ini at its root is a stale early preset fetched by
# nothing. This machine nests the model families under models/ (that
# directory, plus the preset INI at its root, is the whole input to the server
# — which is why nothing is seeded into /etc), and its preset INI is
# machine-scoped, served from the hava-amina/ subdirectory. So each fetch is a
# pair — the URL path under the served directory and the destination path
# under DEST_ROOT — not one string playing both roles. The model paths inside
# llama-server-config.ini are the destination paths with /llama-cpp in front.
#
# Only the model this machine actually serves is fetched here — one ~24 GB
# GGUF, its chat template and the router's preset INI. When the strix box's
# full library is restored the model families land in the same models/
# subdirectory the paths below build, so the destination side needs no change.
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
DEST_ROOT="$MNT_POINT/llama-models"   # bind-mounted as /llama-cpp in llama-server.container
OWNER="keelan"

# Pairs of "URL path destination path" (relative to the served directory and
# to $DEST_ROOT respectively; no path here contains a space).
FILES=(
  "Qwen3.8-27B-GGUF/Qwen3.8-27B-UD-Q6_K_XL.gguf models/Qwen3.8-27B-GGUF/Qwen3.8-27B-UD-Q6_K_XL.gguf"
  "Qwen-Fixed-Chat-Templates/chat_template.jinja models/Qwen-Fixed-Chat-Templates/chat_template.jinja"
)

[ "$EUID" -eq 0 ] || { echo "Please run as root (sudo)." >&2; exit 1; }

# Kill switch: the same lock as nevua-ketana's, though on this machine it
# gates only the fetch (the disk wipe is Ignition's declarative storage and
# cannot be locked). Present means the model tree already exists on the
# volume: skip the fetch, write the done marker so llama-server.service
# starts, and remove the lock — we are the only checker, so this keeps a
# later deliberate re-run from silently no-oping.
LOCK_FILE="/var/lib/provision.lock"
if [ -e "$LOCK_FILE" ]; then
    echo "Lock file $LOCK_FILE present: skipping model fetch."
    touch /var/lib/fetch-models.done
    rm -f "$LOCK_FILE"
    exit 0
fi

# uid/gid looked up, never hardcoded.
OWNER_UID=$(id -u "$OWNER")
OWNER_GID=$(id -g "$OWNER")

# The tree itself, not only its contents: llama-server-config.ini lives at its
# root and $OWNER edits that file without sudo, so the directory has to belong
# to $OWNER as well. install -d inside the loop chowns only the directory it is
# given, and the parents it creates on the way there land as root.
install -d -o "$OWNER_UID" -g "$OWNER_GID" "$DEST_ROOT"

# The preset INI is served from the machine-scoped hava-amina/ subdirectory —
# the tree root's llama-server-config.ini is a stale early copy of it — and
# installed at the tree root, where the container's --models-preset reads it.
echo "Fetching llama-server-config.ini from $BASE_URL/hava-amina/..."
curl --fail --location --silent --show-error \
     --retry 5 --retry-delay 10 --retry-all-errors \
     --output "$DEST_ROOT/llama-server-config.ini" \
     "$BASE_URL/hava-amina/llama-server-config.ini"
chown "$OWNER_UID:$OWNER_GID" "$DEST_ROOT/llama-server-config.ini"
echo "Installed $DEST_ROOT/llama-server-config.ini"

for entry in "${FILES[@]}"; do
    url_rel="${entry%% *}"
    dest_rel="${entry#* }"
    dest="$DEST_ROOT/$dest_rel"
    # install -d: mkdir -p that also hands the new directory to $OWNER, so
    # nothing on the volume is left owned by root.
    install -d -o "$OWNER_UID" -g "$OWNER_GID" "$(dirname "$dest")"

    echo "Fetching $dest_rel from $url_rel..."
    # -f makes a 404 from http.server a failure; --retry-all-errors also retries
    # a truncated body, which is how a server that dies mid-transfer shows up.
    curl --fail --location --silent --show-error \
         --retry 5 --retry-delay 10 --retry-all-errors \
         --output "$dest" "$BASE_URL/$url_rel"

    chown "$OWNER_UID:$OWNER_GID" "$dest"
    echo "Installed $dest"
done

echo "Success! Model files are in $DEST_ROOT"
ls -lR "$DEST_ROOT"
