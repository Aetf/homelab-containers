#!/bin/sh
# Assemble a flashable SD image from build/rootfs.tar + build/state.tar.
# Runs INSIDE a throwaway alpine container (see Justfile `image` recipe) so it
# needs no host tools and no root/loop devices: ext4 via mke2fs -d, FAT via
# mtools, partition table via sfdisk, all operating on plain files.
set -eu

BOOT_MB=${BOOT_MB:-300}
ROOT_MB=${ROOT_MB:-3400}
OUT=build/rpi-host.img

# coreutils: busybox dd lacks conv=sparse
apk add --no-cache -q e2fsprogs dosfstools mtools sfdisk uuidgen tar coreutils

rm -rf build/.asm; mkdir -p build/.asm
cd build/.asm

echo "== extracting rootfs + state overlay"
mkdir root
tar -xpf ../rootfs.tar -C root --numeric-owner
tar -xpf ../state.tar  -C root --numeric-owner
chmod 600 root/etc/ssh/ssh_host_*_key root/etc/shadow

ROOT_UUID=$(uuidgen)
# FAT volume id: 8 hex digits
BOOT_VID=$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')
BOOT_UUID_FSTAB=$(echo "$BOOT_VID" | tr 'a-f' 'A-F' | sed 's/^\(....\)/\1-/')

echo "== generating fstab + cmdline.txt (root=$ROOT_UUID boot=$BOOT_UUID_FSTAB)"
cat > root/etc/fstab <<EOF
UUID=$ROOT_UUID	/	ext4	rw,relatime 0 1
UUID=$BOOT_UUID_FSTAB	/boot	vfat	rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=ascii,shortname=mixed,errors=remount-ro 0 2
/dev/cdrom	/media/cdrom	iso9660	noauto,ro 0 0
/dev/usbdisk	/media/usb	vfat	noauto	0 0
tmpfs	/tmp	tmpfs	nosuid,nodev	0	0
tmpfs	/var/log	tmpfs	nosuid,nodev	0	0
EOF

mkdir bootfs
mv root/boot/* bootfs/
printf 'root=UUID=%s modules=sd-mod,usb-storage,ext4 quiet rootfstype=ext4\n' "$ROOT_UUID" > bootfs/cmdline.txt

echo "== building FAT boot partition"
mkfs.vfat -C -F 32 -n RPIBOOT -i "$BOOT_VID" boot.img $((BOOT_MB * 1024)) >/dev/null
mcopy -i boot.img -s bootfs/* ::/

echo "== building ext4 root partition"
mke2fs -q -t ext4 -d root -U "$ROOT_UUID" -L rpiroot root.img "${ROOT_MB}M"

echo "== assembling partitioned image (A/B root slots)"
# p2 = root slot A (populated), p3 = root slot B (bare partition, no fs):
# future deploys write the inactive slot over ssh and flip cmdline.txt,
# so reflashing never needs physical access again after the first flash.
truncate -s $((1 + BOOT_MB + ROOT_MB + ROOT_MB + 1))M img
sfdisk -q img <<EOF
label: dos
unit: sectors
start=2048, size=$((BOOT_MB * 2048)), type=c
start=$((2048 + BOOT_MB * 2048)), size=$((ROOT_MB * 2048)), type=83
start=$((2048 + (BOOT_MB + ROOT_MB) * 2048)), size=$((ROOT_MB * 2048)), type=83
EOF
dd if=boot.img of=img bs=1M seek=1 conv=notrunc,sparse status=none
dd if=root.img of=img bs=1M seek=$((1 + BOOT_MB)) conv=notrunc,sparse status=none

mv img "../${OUT##*/}"
# keep the bare root partition image + its UUID for the online A/B deploy
mv root.img ../rootpart.img
printf '%s\n' "$ROOT_UUID" > ../rootpart.uuid
cd ..; rm -rf .asm
echo "== done: $OUT (first flash: dd if=$OUT of=/dev/sdX bs=4M conv=fsync)"
echo "==       online redeploy afterwards: just deploy (writes rootpart.img to the inactive slot)"
ls -lhs "${OUT##*/}" rootpart.img
