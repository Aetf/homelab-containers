# homelab-containers — one build engine for every edge device

Alpine-based images for the odd little computers in my homelab, all built the
same way: a `Containerfile` + rootless podman (cross-arch via qemu binfmt),
one directory per target, `just build/deploy/image <target>`. The interesting
part is that the *outputs* differ — the same engine feeds a systemd-nspawn
rootfs, an OCI image, and a flashable SD card:

| Target | Arch | Output | Runs as |
|---|---|---|---|
| `caddy` | aarch64 | rootfs tar → validate-then-swap over ssh | systemd-nspawn container on a UniFi UDM-SE gateway |
| `adguard` | aarch64 | rootfs tar → validate-then-swap (`--check-config`) + DNS health check with auto-rollback | systemd-nspawn container on the same gateway; whole-house DNS |
| `otbr` | arm/v6 | OCI image → `podman save \| ssh podman load` | podman container on a Raspberry Pi 1 B Thread border router (upstream ot-br-posix doesn't ship armv6 images, so this builds from source on Alpine + s6-overlay) |
| `rpi-host` | arm/v6 | flashable SD image (FAT boot + A/B ext4 root slots), assembled rootless | the Raspberry Pi itself (Alpine sys-mode, OpenRC) |

## Design notes

- **Image vs state.** Images carry software only. Everything that makes a
  device *that* device — ssh host keys, DNS state, Thread network data,
  tokens — lives outside the image (bind-mounted `/data` on the gateway,
  dedicated dirs on the Pi) or is overlaid into the artifact at assembly
  time from the live device, into the gitignored `build/`. **No secrets in
  this repo or its history.**
- **Deploys are validate-then-swap.** nspawn targets extract to `<name>.new`,
  validate the live config with the *new* binary inside a chroot, then
  stop/swap/start, keeping the previous rootfs at `<name>.old` for instant
  rollback. The DNS target additionally health-checks after start and
  auto-rolls-back, capping a bad image at ~35s of downtime.
- **The Pi reflashes online.** The SD image carries two root partitions;
  `just deploy rpi-host` writes the new root to the inactive slot over ssh,
  re-syncs live state onto it, flips `cmdline.txt` (backup kept), reboots
  and health-checks. Only the very first flash of a card touches hardware.
- **Version pins in one place.** `versions.env` pins ALPINE_VERSION /
  S6_OVERLAY_VERSION for every target (the top-level Justfile exports them);
  app versions pin in each target's Justfile. Upgrades are a bump + a
  per-target rebuild, staged low-risk-first.
- **Shared pieces.** `shared/install-s6.sh` installs s6-overlay in any
  Containerfile via `--build-context shared=../shared`; s6-overlay is the
  init in every container image (`/init`, copied to `/sbin/init` so
  `systemd-nspawn --boot` finds it). Emulated builds stay tolerable through
  layer caching plus `--mount=type=cache` ccache/npm mounts (see otbr).

## Hard-won lessons (a.k.a. why some of this looks paranoid)

- **Never use `podman build --output type=tar`.** With a warm layer cache it
  can silently emit tars missing whole layers' contents — down to every
  busybox symlink — while the image itself is fine. Every build recipe tags
  the image and flattens it with `podman create` + `podman export` instead.
- The exported tar also drops xattrs/file capabilities (fine while services
  run as root in these containers; revisit before relying on file caps).
- **s6-rc oneshot `up` files are parsed by execlineb, not a shell.** Quoting
  and multi-command shell syntax misparse silently; keep `up` a single path
  to a real script.
- **nspawn + s6-overlay needs `KillSignal=SIGKILL` and
  `S6_KILL_GRACETIME=0`** in the `.nspawn` unit, or stops leave stale
  s6-supervise processes that wedge the unit cgroup (219/CGROUP on the next
  start).
- podman healthchecks don't run on non-systemd hosts (no timer to fire
  them); a container can sit in "(starting)" forever and be perfectly fine.

## Deployment config lives elsewhere

This repo owns what is *inside* the images. Host-side deployment config
(`.nspawn` units, boot-time restore scripts, drift checking, encrypted
backups) is managed separately with the rest of my dotfiles; the split keeps
this repo shareable and the device-recovery path self-contained there.

## TODO

- caddy: ssh host keys are baked at build (`ssh-keygen -A`) so they rotate
  every rebuild → known_hosts churn; move generation to a first-boot s6
  oneshot persisting into `/data/caddy`.
