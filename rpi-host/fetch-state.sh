#!/usr/bin/env bash
# Fetch device state from the LIVE rpi into build/state.tar (gitignored).
# State = everything that makes this device *this* device and must survive a
# reflash: ssh host identity, root password hash, Thread network state,
# hass-agent registration, deployed OTBR image tag, HA registration token.
# Run from the rpi-host target dir. If the device is dead, restore state.tar
# from whatever backup exists instead of running this.
set -euo pipefail
mkdir -p build

ssh rpi 'tar -C / -cf - --numeric-owner \
    etc/ssh/ssh_host_rsa_key etc/ssh/ssh_host_rsa_key.pub \
    etc/ssh/ssh_host_ecdsa_key etc/ssh/ssh_host_ecdsa_key.pub \
    etc/ssh/ssh_host_ed25519_key etc/ssh/ssh_host_ed25519_key.pub \
    etc/shadow \
    var/lib/otbr var/lib/hass-agent \
    root/otbr/.env' > build/state.tar

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
tar -rf build/state.tar --owner=0 --group=0 --mode=600 \
    --transform='s|.*|root/hass-agent/.env|' build/hass-reg.env
rm build/hass-reg.env

echo "state.tar contents:"
tar -tf build/state.tar
