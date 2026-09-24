#!/bin/sh
# Assemble the rpi host's boot artifacts from build/rootfs.tar. Runs INSIDE a
# throwaway alpine container (see the Justfile) so it needs no host tools and
# no root/loop devices: ext4 via mke2fs -d, FAT via mtools, partition table
# via sfdisk, all on plain files.
#
#   assemble.sh slot  one A/B slot - build/rootpart.img (+ rootpart.uuid) and
#                     build/slot-boot.tar - everything `just deploy` installs.
#                     Stateless: no device data goes into a slot.
#   assemble.sh card  the full card image build/rpi-host.img for a first
#                     flash, from the slot artifacts plus build/state.tar
#                     (a backup of the device's /data).
#
# Card layout. MBR: the Pi 1 boot ROM and firmware read no GPT. The firmware
# only reads the two FAT partitions, which must be primary; the Linux ones
# live in the extended partition. Offsets are 4 MiB aligned (SD erase blocks).
#   p1 RPIBOOT  FAT32  firmware, config.txt, slot.txt (committed slot), a/ b/
#   p2 RPITRY   FAT32  one-shot trial boot, rewritten by every deploy
#   p3          extended, to the end of the card
#   p5 / p6     ext4   root of slot a / b
#   p7 rpidata  ext4   /data; grown to the end of the card on first boot
# Partition numbers are relied on by rootfs/usr/local/sbin/rpi-slot and
# rootfs/etc/init.d/rpi-growdata.
set -eu

MODE=${1:?usage: assemble.sh slot|card}
BOOT_MB=256
TRY_MB=128
ROOT_MB=1536
DATA_MB=${DATA_MB:-1024}

case $MODE in
slot)
    apk add --no-cache -q e2fsprogs tar
    rm -rf build/.slot; mkdir -p build/.slot/root build/.slot/boot/fw build/.slot/boot/os
    cd build/.slot

    echo "== extracting rootfs"
    tar -xpf ../rootfs.tar -C root --numeric-owner
    ROOT_UUID=$(cat /proc/sys/kernel/random/uuid)

    echo "== splitting /boot into firmware and OS files"
    # Firmware (bootcode.bin, start*.elf, fixup*.dat) sits at a FAT
    # partition's root; everything else the firmware loads is an OS file
    # and goes into the slot directory. FAT has no symlinks (the rootfs
    # carries /boot/boot -> .), and config.txt is ours (../../bootfs).
    for f in root/boot/*; do
        n=${f##*/}
        if [ -L "$f" ]; then rm "$f"; continue; fi
        case $n in
        bootcode.bin | start*.elf | fixup*.dat) mv "$f" boot/fw/ ;;
        config.txt | cmdline.txt | config-* | System.map-*) rm -rf "$f" ;;
        *) mv "$f" boot/os/ ;;
        esac
    done
    # os_prefix applies to overlays only if <prefix>overlays/README exists
    [ -d boot/os/overlays ] && : >boot/os/overlays/README
    cp /work/bootfs/config.txt boot/
    # The root is named by partition, not by this build's fs UUID: the same
    # build in both slots would make a UUID ambiguous. rpi-slot (and the card
    # mode below) prepends root=<slot's partition> and appends
    # rpislot=<slot>[:trial]; fstab has no / entry for the same reason
    # (OpenRC's root service remounts / rw without one).
    echo 'modules=sd-mod,usb-storage,ext4 rootfstype=ext4 panic=10 quiet' >boot/cmdline.base
    echo "$ROOT_UUID" >boot/root.uuid

    echo "== generating fstab"
    cat >root/etc/fstab <<EOF
LABEL=RPIBOOT	/boot	vfat	rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=ascii,shortname=mixed,errors=remount-ro 0 2
LABEL=rpidata	/data	ext4	rw,relatime 0 2
/data/otbr	/var/lib/otbr	none	bind 0 0
/data/hass-agent	/var/lib/hass-agent	none	bind 0 0
/data/containers	/var/lib/containers	none	bind 0 0
/dev/cdrom	/media/cdrom	iso9660	noauto,ro 0 0
/dev/usbdisk	/media/usb	vfat	noauto	0 0
tmpfs	/tmp	tmpfs	nosuid,nodev	0	0
tmpfs	/var/log	tmpfs	nosuid,nodev	0	0
EOF

    echo "== building ext4 root partition image"
    mke2fs -q -t ext4 -d root -U "$ROOT_UUID" -L rpiroot root.img "${ROOT_MB}M"
    tar -C boot -cf slot-boot.tar fw os config.txt cmdline.base root.uuid

    mv root.img ../rootpart.img
    mv slot-boot.tar ../
    printf '%s\n' "$ROOT_UUID" >../rootpart.uuid
    cd ..; rm -rf .slot
    echo "== done: rootpart.img + slot-boot.tar (root $ROOT_UUID)"
    ls -lhs rootpart.img slot-boot.tar
    ;;

card)
    apk add --no-cache -q e2fsprogs dosfstools mtools sfdisk tar coreutils
    for f in rootpart.img rootpart.uuid slot-boot.tar state.tar; do
        [ -s build/$f ] || { echo "ERROR: build/$f missing" >&2; exit 1; }
    done
    rm -rf build/.card; mkdir -p build/.card/boot build/.card/slot build/.card/data
    cd build/.card

    echo "== p1 RPIBOOT: firmware + slot a"
    tar -xf ../slot-boot.tar -C slot
    cp -r slot/fw/. slot/config.txt boot/
    echo "os_prefix=a/" >boot/slot.txt
    cp -r slot/os boot/a
    echo "root=/dev/mmcblk0p5 $(cat slot/cmdline.base) rpislot=a" >boot/a/cmdline.txt
    mkfs.vfat -C -F 32 -n RPIBOOT boot.img $((BOOT_MB * 1024)) >/dev/null
    mcopy -i boot.img -s boot/* ::/

    echo "== p2 RPITRY: empty until the first deploy stages a trial"
    mkfs.vfat -C -F 32 -n RPITRY try.img $((TRY_MB * 1024)) >/dev/null

    echo "== p7 rpidata from state.tar"
    mkdir -p data/ssh data/otbr data/hass-agent data/containers data/env data/identity
    tar -xpf ../state.tar -C data --numeric-owner
    mke2fs -q -t ext4 -d data -L rpidata data.img "${DATA_MB}M"

    echo "== partition table"
    # all in MiB; sfdisk wants sectors (x2048)
    p1=4
    p2=$((p1 + BOOT_MB))
    ext=$((p2 + TRY_MB))
    p5=$((ext + 4))
    p6=$((p5 + ROOT_MB + 4))
    p7=$((p6 + ROOT_MB + 4))
    total=$((p7 + DATA_MB + 4))
    truncate -s "${total}M" img
    sfdisk -q img <<EOF
label: dos
unit: sectors
start=$((p1 * 2048)), size=$((BOOT_MB * 2048)), type=c
start=$((p2 * 2048)), size=$((TRY_MB * 2048)), type=c
start=$((ext * 2048)), size=$(((total - ext) * 2048)), type=5
start=$((p5 * 2048)), size=$((ROOT_MB * 2048)), type=83
start=$((p6 * 2048)), size=$((ROOT_MB * 2048)), type=83
start=$((p7 * 2048)), size=$((DATA_MB * 2048)), type=83
EOF
    for part in "boot.img $p1" "try.img $p2" "../rootpart.img $p5" "data.img $p7"; do
        set -- $part
        dd if="$1" of=img bs=1M seek="$2" conv=notrunc,sparse status=none
    done

    mv img ../rpi-host.img
    cd ..; rm -rf .card
    echo "== done: build/rpi-host.img, slot a committed (first flash: dd if=rpi-host.img of=/dev/sdX bs=4M conv=fsync)"
    ls -lhs rpi-host.img
    ;;

*)
    echo "usage: assemble.sh slot|card" >&2
    exit 2
    ;;
esac
