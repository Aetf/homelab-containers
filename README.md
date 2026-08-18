# homelab-containers — unified alpine image builds for edge devices

Single build engine (Containerfile + rootless podman, cross-arch via qemu
binfmt) producing alpine-based images for the homelab's edge devices. Each
target is one directory with a `Containerfile`, an optional `rootfs/` overlay,
and a `Justfile` implementing `build` and `deploy` for its output kind.

```bash
just build <target>     # build only
just deploy <target>    # build + ship + restart
```

## Targets

| Target | Arch | Output adapter | Runs as |
|---|---|---|---|
| `caddy` | aarch64 | rootfs tar (`podman build --output type=tar`) → validate-then-swap over ssh | systemd-nspawn container on the UDM-SE (`gw`) |
| `adguard` | aarch64 | rootfs tar → validate-then-swap (`--check-config`) over ssh | systemd-nspawn container on the UDM-SE; whole-house DNS. State in `/data/adguard` (separated 2026-08-17) |
| `otbr` | arm/v6 | OCI image → `podman save \| ssh rpi podman load` | podman container on the RPi Thread border router |
| `rpi-host` | arm/v6 | rootfs tar → `just image`: flashable SD .img (FAT boot + ext4 root, assembled rootless in a helper container), personalized with state fetched from the live device | the RPi 1 B TBR host itself (alpine sys-mode, OpenRC) |

`rpi-host` has no push-deploy: flashing the SD is physical. Its image carries
NO secrets in git — device identity (ssh host keys, HA token, Thread state,
root password hash) is pulled from the live device into gitignored `build/`
at assembly time and overlaid into the image.

## Shared pieces

- `versions.env` — canonical ALPINE_VERSION / S6_OVERLAY_VERSION, exported to
  target Justfiles by the top-level Justfile. Routine upgrade = bump here,
  rebuild targets one by one (low-risk first).
- `shared/install-s6.sh` — s6-overlay download/extract, used by every
  Containerfile via `--build-context shared=../shared` + bind mount. All
  images use s6-overlay as init (`/init`; nspawn targets also copy it to
  `/sbin/init` so `Boot=on` finds it).
- Emulated builds stay tolerable through podman layer caching plus
  `--mount=type=cache` ccache/npm mounts (see otbr).

## Division of responsibility

This repo owns the **software layer** (what is inside the image). It does NOT
own:

- **deployment config on gw** (`.nspawn` units, on_boot.d, drift checking):
  `~/.config/gw-config` (yadm) — nspawn units live there because its
  on_boot.d restores them from `/data/gw-config/nspawn` after firmware
  updates. Do not add `.nspawn` files or scp steps here.
- **runtime state and secrets**: `/data/...` on the device (survives deploys;
  a deploy wipes the container rootfs). Caddyfile, cf_token, AdGuardHome
  data, otbr's `/var/lib/otbr` are all state, not image content.

NO SECRETS in this repo — images and git history are meant to be shareable.
(A CF API token used to live in a `caddy.nspawn` here; removed 2026-08-17,
rotate + scrub history before ever publishing this repo.)

## Known limitations

- **Never use `podman build --output type=tar`**: with a warm layer cache it
  can silently emit tars missing entire layers' contents — including every
  symlink down to busybox applets (bitten 2026-08-18 on rpi-host; the image
  itself was fine). All build recipes therefore tag the image and flatten it
  via `podman create` + `podman export`.
- The exported rootfs tar drops xattrs, including file capabilities
  (verified 2026-08-17: xcaddy's `setcap cap_net_bind_service` on the caddy
  binary is absent from the tar). Harmless while services run as root inside
  the containers; revisit before any target relies on file caps for non-root
  low-port binding.

## TODO

- caddy: ssh host keys are baked at build (`ssh-keygen -A`) so they rotate on
  every rebuild → known_hosts churn; move generation to a first-boot s6
  oneshot persisting into `/data/caddy`.
- otbr: `otbr/mise.toml` (gemini-cli/node) predates the merge, review whether
  still needed.
