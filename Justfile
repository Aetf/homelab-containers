# Unified alpine image builds for homelab edge devices.
# Usage: just build <target> / just deploy <target>
# Targets: caddy, adguard, zerotier (build-only), otbr, rpi-host
# Base versions are pinned in versions.env and exported to target Justfiles.

# dotenv values are exported into recipe environments automatically, so the
# per-target `just` invocations below see ALPINE_VERSION / S6_OVERLAY_VERSION.
set dotenv-filename := "versions.env"

default:
    @just --list

build target:
    just --justfile {{target}}/Justfile --working-directory {{target}} build

# Extra args pass through to the target Justfile as variable overrides,
# e.g. `just deploy adguard instance=bob`.
deploy target *args:
    just --justfile {{target}}/Justfile --working-directory {{target}} {{args}} deploy

# rpi-host only: assemble the flashable SD image
image target:
    just --justfile {{target}}/Justfile --working-directory {{target}} image
