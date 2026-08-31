#!/bin/bash
#
# nevua-ketana: put the llama.cpp model files onto the storage volume.
#
# The volume comes out of setup-storage.sh empty, and a ~30 GB GGUF is far too
# large to embed in an Ignition config, so it is fetched over the LAN. Run once
# by fetch-models.service, after the volume is mounted.
#
# The server side is a plain python http.server on erevrav (192.168.0.24), and
# the directory it serves IS the layout under /var/mnt/storage/llama-models
# (it is the old machine's /mnt/20tb-hdd/llama-models, copied verbatim), so one
# path string is both the URL suffix and the destination suffix:
#
#   python3 -m http.server 33334 \
#     --directory /mnt/storage/nevua-ketana-backup/20tb-hdd/llama-models
#
# Only the model this machine actually serves is fetched here — one GGUF plus
# its chat template, ~30 GB. The whole tree is several TB (~6 h on the wire);
# when that restore happens it is the same directory mapping, one rsync:
#
#   rsync -aHAXx --info=progress2 \
#     /mnt/storage/nevua-ketana-backup/20tb-hdd/llama-models/ \
#     keelan@192.168.0.45:/var/mnt/storage/llama-models/
#
# Nothing about these files is discovered at runtime: every entry below is
# "<bytes> <path>", the sizes read from ls -l on erevrav on 2026-08-30. A file
# whose length does not match is a hard error, which is the point — a truncated
# GGUF loads and then answers with garbage.
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

# "<expected bytes> <path relative to the served directory>"
# Every path below is also <path> under /models in llama-server-config.ini.
FILES=(
  "31457991680 Qwen3.8-27B-GGUF/Qwen3.8-27B-UD-Q8_K_XL.gguf"
  "27167 Qwen-Fixed-Chat-Templates/chat_template.jinja"
)

[ "$EUID" -eq 0 ] || { echo "Please run as root (sudo)." >&2; exit 1; }

# uid/gid looked up, never hardcoded — see step 10 of setup-storage.sh.
OWNER_UID=$(id -u "$OWNER")
OWNER_GID=$(id -g "$OWNER")

# Wait for the volume rather than race it. fetch-models.service is
# After=setup-storage.service, but on the boot that *creates* the volume that is
# not the same as being after the mount: setup-storage.service starts
# var-mnt-storage.mount with --no-block at the end of its own job, and an After=
# edge cannot order against a job that does not exist yet (the mount job in this
# boot's transaction was skipped by its own condition gate, marker absent). So the
# mount can still be in flight when this runs. Writing into an unmounted mount
# point would put 30 GB on the OS disk and hide it under the volume afterwards.
for _ in {1..60}; do
    mountpoint -q "$MNT_POINT" && break
    sleep 5
done
if ! mountpoint -q "$MNT_POINT"; then
    echo "Error: $MNT_POINT was not mounted within 5 minutes." >&2
    exit 1
fi

for entry in "${FILES[@]}"; do
    read -r want_bytes rel_path <<< "$entry"
    dest="$DEST_ROOT/$rel_path"
    # install -d: mkdir -p that also hands the new directory to $OWNER, so
    # nothing on the volume is left owned by root.
    install -d -o "$OWNER_UID" -g "$OWNER_GID" "$(dirname "$dest")"

    # A re-run after a failure: a file of the expected length is already done.
    if [ -f "$dest" ] && [ "$(stat -c %s "$dest")" -eq "$want_bytes" ]; then
        echo "Already present: $rel_path ($want_bytes bytes)"
        continue
    fi

    echo "Fetching $rel_path ($want_bytes bytes) from $BASE_URL..."
    # .part + mv: the real path only ever appears once a complete file is behind
    # it, so an interrupted run cannot leave something that looks installed.
    # -f makes a 404 from http.server a failure; --retry-all-errors also retries
    # a truncated body, which is how a server that dies mid-transfer shows up.
    curl --fail --location --silent --show-error \
         --retry 5 --retry-delay 10 --retry-all-errors \
         --output "$dest.part" "$BASE_URL/$rel_path"

    got_bytes=$(stat -c %s "$dest.part")
    if [ "$got_bytes" -ne "$want_bytes" ]; then
        echo "Error: $rel_path is $got_bytes bytes, expected $want_bytes." >&2
        exit 1
    fi

    mv "$dest.part" "$dest"
    chown "$OWNER_UID:$OWNER_GID" "$dest"
    echo "Installed $dest ($got_bytes bytes)"
done

echo "Success! Model files are in $DEST_ROOT"
ls -lR "$DEST_ROOT"
