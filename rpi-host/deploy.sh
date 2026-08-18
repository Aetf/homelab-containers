#!/usr/bin/env bash
# Online A/B redeploy of the rpi host (no physical SD access needed once the
# card carries the A/B layout from a first physical flash of rpi-host.img):
#   1. write build/rootpart.img to the INACTIVE root slot (unmounted -> safe)
#   2. re-sync device identity/state onto it (the baked copy is minutes old)
#   3. flip /boot/cmdline.txt to the new slot's UUID (backup kept in
#      cmdline.txt.prev - manual rollback = restore it and reboot)
#   4. reboot, wait for ssh, verify the new slot booted
#   5. reinstall container images (the fresh slot has none): otbr via
#      ../otbr's deploy, hass-agent pulls from ghcr by its own service
# A failed boot needs physical access (flip cmdline back on any card reader);
# the Thread mesh tolerates this BR being down meanwhile.
set -euo pipefail

uuid=$(cat build/rootpart.uuid)
[ -s build/rootpart.img ] || { echo "run 'just image' first" >&2; exit 1; }

cur=$(ssh rpi "sed -n 's/.*root=UUID=\([0-9a-f-]*\).*/\1/p' /proc/cmdline")
p2=$(ssh rpi "blkid /dev/mmcblk0p2 | sed -n 's/.*UUID=\"\([0-9a-f-]*\)\".*/\1/p'")
if [ "$cur" = "$p2" ]; then target=/dev/mmcblk0p3; else target=/dev/mmcblk0p2; fi
ssh rpi "test -b $target" || { echo "no $target - card lacks the A/B layout" >&2; exit 1; }
echo "active slot UUID=$cur; writing new root ($uuid) to inactive $target"

gzip -c build/rootpart.img | ssh rpi "gunzip -c | dd of=$target bs=1M conv=fsync 2>/dev/null"

echo "re-syncing live state onto the new slot"
ssh rpi "mount $target /mnt \
    && cp -a /etc/ssh/ssh_host_* /mnt/etc/ssh/ \
    && cp -a /etc/shadow /mnt/etc/ \
    && rm -rf /mnt/var/lib/otbr /mnt/var/lib/hass-agent \
    && cp -a /var/lib/otbr /var/lib/hass-agent /mnt/var/lib/ \
    && cp -a /root/otbr/.env /mnt/root/otbr/.env \
    && { cp -a /root/hass-agent/.env /mnt/root/hass-agent/.env 2>/dev/null || true; } \
    && umount /mnt"

echo "flipping cmdline.txt and rebooting"
ssh rpi "cp /boot/cmdline.txt /boot/cmdline.txt.prev \
    && sed -i 's/root=UUID=[0-9a-f-]*/root=UUID=$uuid/' /boot/cmdline.txt \
    && (sleep 1; reboot) >/dev/null 2>&1 &" || true

echo "waiting for the device to come back"
ok=
for i in $(seq 1 60); do
    if booted=$(ssh -o ConnectTimeout=5 -o BatchMode=yes rpi \
            "sed -n 's/.*root=UUID=\([0-9a-f-]*\).*/\1/p' /proc/cmdline" 2>/dev/null); then
        if [ "$booted" = "$uuid" ]; then ok=1; echo "up on new slot (attempt $i)"; break
        elif [ "$booted" = "$cur" ]; then continue  # still the old boot going down
        else echo "ERROR: booted unexpected slot $booted" >&2; exit 1; fi
    fi
done
[ -n "$ok" ] || { echo "ERROR: device did not come back on the new slot; physical rollback: restore cmdline.txt.prev" >&2; exit 1; }

echo "reinstalling otbr container image"
just --justfile ../otbr/Justfile --working-directory ../otbr deploy

echo "final health check"
ssh rpi "podman exec otbr ot-ctl state"
echo "deploy complete; previous root remains on the other slot (rollback: restore /boot/cmdline.txt.prev, reboot)"
