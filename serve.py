#!/usr/bin/env python3
#
# The two HTTP servers a nevua-ketana install needs from this machine, in one
# foreground command: Ctrl+C stops both. Run it in a tmux pane and leave it up
# for the whole install — see "Installing onto a machine" in README.md.

import http.server
import signal
import threading
from functools import partial
from pathlib import Path

IGNITION_DIR = Path("/mnt/storage/ignition-files/builds")
MODELS_DIR = Path("/mnt/storage/nevua-ketana-backup/20tb-hdd/llama-models")

SERVERS = [
    (33333, IGNITION_DIR, "the .ign — fetched by coreos-installer"),
    (33334, MODELS_DIR, "the models — fetched by fetch-models.service"),
]

servers = []
for port, directory, note in SERVERS:
    handler = partial(http.server.SimpleHTTPRequestHandler, directory=str(directory))
    server = http.server.ThreadingHTTPServer(("", port), handler)
    server.daemon_threads = True  # don't block shutdown on open connections
    threading.Thread(target=server.serve_forever, daemon=True).start()
    servers.append(server)

for port, directory, note in SERVERS:
    print(f"  :{port}  {directory}  ({note})")
print("Ctrl+C stops both.")

try:
    signal.pause()  # block until Ctrl+C (KeyboardInterrupt) or SIGTERM
except KeyboardInterrupt:
    pass  # Ctrl+C: fall through to the shutdown below, no traceback
finally:
    for server in servers:
        server.shutdown()
        server.server_close()
