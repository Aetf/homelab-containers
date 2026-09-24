#!/usr/bin/env bash
# Back up the LIVE device's /data into build/state.tar (gitignored): the
# device's whole identity and state - ssh host keys, root password hash,
# Thread network state, hass-agent registration, pinned OTBR tag, HA
# registration token. `just image` seeds a card's /data from it. Container
# storage is left out: images are pushed (otbr) or pulled (hass-agent) again.
# Run from the rpi-host target dir.
#
# Device unreachable (dead, or offline awaiting this very reflash): keep the
# existing build/state.tar and build from it. The fetch is staged in a temp
# file and moved into place only on success, so a failed fetch never
# clobbers the last good state.tar.
set -euo pipefail
mkdir -p build

if ! ssh -o ConnectTimeout=10 -o BatchMode=yes rpi true 2>/dev/null; then
    if [ -s build/state.tar ]; then
        echo "WARNING: rpi unreachable; reusing build/state.tar from $(date -r build/state.tar '+%F %T')" >&2
        exit 0
    fi
    echo "ERROR: rpi unreachable and no build/state.tar to fall back on." >&2
    echo "       Restore it from a backup of the device's /data." >&2
    exit 1
fi

tmp=$(mktemp build/state.tar.XXXXXX)
trap 'rm -f "$tmp"' EXIT

echo "fetching /data from rpi..."
ssh rpi 'tar -C /data -cf - --numeric-owner --exclude=./containers --exclude=./lost+found .' > "$tmp"
mv "$tmp" build/state.tar

echo "state.tar contents:"
tar -tf build/state.tar
