#!/usr/bin/env bash
# Fetch device state from the LIVE rpi into build/state.tar (gitignored).
# State = everything that makes this device *this* device and must survive a
# reflash: ssh host identity, root password hash, Thread network state,
# hass-agent registration, deployed OTBR image tag, HA registration token.
# Run from the rpi-host target dir.
#
# Device unreachable (dead, or offline awaiting this very reflash): keep the
# existing build/state.tar and build from it. Everything is staged in a temp
# file and moved into place only on success, so a failed fetch never clobbers
# the last good state.tar.
set -euo pipefail
mkdir -p build

if ! ssh -o ConnectTimeout=10 -o BatchMode=yes rpi true 2>/dev/null; then
    if [ -s build/state.tar ]; then
        echo "WARNING: rpi unreachable; reusing build/state.tar from $(date -r build/state.tar '+%F %T')" >&2
        exit 0
    fi
    echo "ERROR: rpi unreachable and no build/state.tar to fall back on." >&2
    echo "       Restore it from a backup, or extract it from a previous image's root partition." >&2
    exit 1
fi

tmp=$(mktemp build/state.tar.XXXXXX)
trap 'rm -f "$tmp" build/hass-reg.env' EXIT

echo "fetching device state from rpi..."
ssh rpi 'tar -C / -cf - --numeric-owner \
    etc/ssh/ssh_host_rsa_key etc/ssh/ssh_host_rsa_key.pub \
    etc/ssh/ssh_host_ecdsa_key etc/ssh/ssh_host_ecdsa_key.pub \
    etc/ssh/ssh_host_ed25519_key etc/ssh/ssh_host_ed25519_key.pub \
    etc/shadow \
    var/lib/otbr var/lib/hass-agent \
    root/otbr/.env' > "$tmp"

# HA registration token: lives only on the device (historically inline in
# compose.yml; the image's compose reads ${HASS_REG_TOKEN} from .env instead).
token=$(ssh rpi "grep -A1 -- '--token' /root/hass-agent/compose.yml | tail -1 | tr -d ' \"-' ")
if [ -z "$token" ]; then
    # device already migrated to the .env layout
    token=$(ssh rpi "sed -n 's/^HASS_REG_TOKEN=//p' /root/hass-agent/.env")
fi
[ -n "$token" ] || { echo "ERROR: could not extract HASS_REG_TOKEN from device" >&2; exit 1; }
printf 'HASS_REG_TOKEN=%s\n' "$token" > build/hass-reg.env
chmod 600 build/hass-reg.env
tar -rf "$tmp" --owner=0 --group=0 --mode=600 \
    --transform='s|.*|root/hass-agent/.env|' build/hass-reg.env
rm build/hass-reg.env
mv "$tmp" build/state.tar

echo "state.tar contents:"
tar -tf build/state.tar
