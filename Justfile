# Unified alpine image builds for homelab edge devices.
# Usage: just build <target> / just deploy <target>   (targets: caddy, otbr)
# Base versions are pinned in versions.env and exported to target Justfiles.

# dotenv values are exported into recipe environments automatically, so the
# per-target `just` invocations below see ALPINE_VERSION / S6_OVERLAY_VERSION.
set dotenv-filename := "versions.env"

default:
    @just --list

build target:
    just --justfile {{target}}/Justfile --working-directory {{target}} build

deploy target:
    just --justfile {{target}}/Justfile --working-directory {{target}} deploy

# rpi-host only: assemble the flashable SD image
image target:
    just --justfile {{target}}/Justfile --working-directory {{target}} image
