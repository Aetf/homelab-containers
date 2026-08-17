# Unified alpine image builds for homelab edge devices.
# Usage: just build <target> / just deploy <target>   (targets: caddy, otbr)
# Base versions are pinned in versions.env and exported to target Justfiles.

set dotenv-filename := "versions.env"
set dotenv-export := true

default:
    @just --list

build target:
    just --justfile {{target}}/Justfile --working-directory {{target}} build

deploy target:
    just --justfile {{target}}/Justfile --working-directory {{target}} deploy
