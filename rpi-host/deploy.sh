#!/usr/bin/env bash
# Online A/B update of the rpi host with the slot built by `just slot`
# (mechanism and card layout: rootfs/usr/local/sbin/rpi-slot).
#
#   stage   write build/rootpart.img to the spare root partition and install
#           build/slot-boot.tar as the spare slot's kernel files, plus a
#           complete trial boot partition (RPITRY) for it
#   trial   reboot once into RPITRY; wait for the device to come back
#   verify  health-check the running slot (network, otbr, hass-agent)
#   commit  make the trial slot permanent, reboot normally, verify again
#   all     stage, trial, verify, commit - a failed verify reboots the device
#           back to the committed slot and exits non-zero
#
# Until `commit`, every reset of the device - kernel panic (panic=10), hang
# (hardware watchdog), plain reboot, power loss, the on-device trial
# deadline - returns to the committed slot, so this script dying mid-way is
# safe. Device state lives on /data and is shared by both slots; nothing is
# copied between them.
set -euo pipefail
cd "$(dirname "$0")"

SSH=(ssh -o ConnectTimeout=5 -o BatchMode=yes rpi)
# This checkout's rpi-slot, pushed for each use so host and device agree on
# the protocol even when the running slot carries an older copy.
RS=/run/rpi-slot-deploy
push_rs() { "${SSH[@]}" "cat > $RS && chmod +x $RS" < rootfs/usr/local/sbin/rpi-slot; }
status() {
    push_rs
    eval "$("${SSH[@]}" "$RS status")"
    echo "device: booted slot $booted (trial: $trial), committed slot $committed"
}
boot_id() { "${SSH[@]}" cat /proc/sys/kernel/random/boot_id 2>/dev/null; }
other() { case $1 in a) echo b ;; b) echo a ;; esac; }

# Wait for the device to finish a reboot, identified by a new boot_id.
wait_reboot() {
    local old=$1 id i
    echo "waiting for the device to come back (usually 1-3 min)..."
    for i in $(seq 1 120); do
        if id=$(boot_id) && [ -n "$id" ] && [ "$id" != "$old" ]; then return 0; fi
        sleep 5
    done
    echo "ERROR: device did not come back within 10 min" >&2
    return 1
}

stage() {
    [ -s build/rootpart.img ] && [ -s build/slot-boot.tar ] ||
        { echo "ERROR: run 'just slot' first" >&2; exit 1; }
    status
    local target
    target=$(other "$committed")
    echo "writing root to slot $target (compressed stream; a few minutes on the Pi)..."
    gzip -1 -c build/rootpart.img | "${SSH[@]}" "$RS write-root $target"
    echo "installing slot $target's kernel files and the trial partition..."
    "${SSH[@]}" "$RS stage $target" < build/slot-boot.tar
}

trial() {
    status
    local target id
    target=$(other "$committed")
    id=$(boot_id)
    echo "trial-booting slot $target..."
    "${SSH[@]}" "$RS trial" || true   # the connection drops as the device reboots
    wait_reboot "$id"
    status
    if [ "$booted" = "$committed" ]; then
        echo "ERROR: trial boot of slot $target failed; the firmware fell back to slot $committed" >&2
        exit 1
    fi
    [ "$booted" = "$target" ] && [ "$trial" = yes ] ||
        { echo "ERROR: unexpected boot state after trial" >&2; exit 1; }
}

# Healthy = otbr attached to the Thread network and hass-agent running.
# otbr needs a minute or two after boot to (re)attach.
verify() {
    local i state=
    echo "checking health: waiting for otbr to attach to the Thread network (up to 5 min)..."
    for i in $(seq 1 30); do
        state=$("${SSH[@]}" "podman exec otbr ot-ctl state 2>/dev/null | head -1" 2>/dev/null | tr -d '\r') || true
        case $state in leader | router | child) break ;; esac
        sleep 10
    done
    case $state in
    leader | router | child) echo "otbr: $state" ;;
    *) echo "UNHEALTHY: otbr state '${state:-unavailable}'" >&2; return 1 ;;
    esac
    "${SSH[@]}" "rc-service hass-agent status" | grep -q started ||
        { echo "UNHEALTHY: hass-agent not started" >&2; return 1; }
    echo "hass-agent: started"
}

commit() {
    status
    [ "$trial" = yes ] || { echo "ERROR: not in a trial boot" >&2; exit 1; }
    "${SSH[@]}" "$RS commit"
    local id
    id=$(boot_id)
    echo "rebooting normally to confirm the committed slot boots on its own..."
    "${SSH[@]}" reboot || true
    wait_reboot "$id"
    status
    [ "$booted" = "$committed" ] && [ "$trial" = no ] ||
        { echo "ERROR: committed slot did not boot" >&2; exit 1; }
    verify
}

case ${1:-all} in
status) status ;;
stage) stage ;;
trial) trial ;;
verify) verify ;;
commit) commit ;;
all)
    stage
    trial
    if ! verify; then
        id=$(boot_id)
        echo "rolling back: plain reboot returns to the committed slot..."
        "${SSH[@]}" reboot || true
        wait_reboot "$id"
        status
        exit 1
    fi
    commit
    echo "deploy complete: slot $booted committed"
    ;;
*)
    echo "usage: deploy.sh [status|stage|trial|verify|commit|all]" >&2
    exit 2
    ;;
esac
