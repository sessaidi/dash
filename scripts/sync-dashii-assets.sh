#!/bin/sh
# Copies the Dashii rig (atlas, rig, clips) from the Codex PersonaCat project into Dash.
# Re-run whenever the art or clips change: Dash bundles Dash/Resources/Dashii.
set -eu
SRC="${1:-$(ls -d "$HOME"/Documents/Codex/*/*/outputs/PersonaCat/assets 2>/dev/null | tail -1)}"
DEST="$(cd "$(dirname "$0")/.." && pwd)/Dash/Resources/Dashii"
[ -f "$SRC/rig.json" ] || { echo "No Dashii assets at $SRC" >&2; exit 1; }
mkdir -p "$DEST"
for f in atlas.png atlas.json rig.json animations.json; do cp "$SRC/$f" "$DEST/$f"; done
echo "Synced Dashii assets from $SRC"
