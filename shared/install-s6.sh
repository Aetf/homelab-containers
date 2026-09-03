#!/bin/sh
# Download and extract s6-overlay (noarch + arch tarballs) into DEST.
#
# Usage (in a Containerfile, with `--build-context shared=../shared`):
#   ARG S6_OVERLAY_VERSION
#   ARG TARGETARCH
#   ARG TARGETVARIANT
#   RUN --mount=type=bind,from=shared,target=/shared sh /shared/install-s6.sh /install
#
# Requires curl and xz-capable tar in the running stage.
set -eu

DEST="${1:?usage: install-s6.sh DEST}"
: "${S6_OVERLAY_VERSION:?S6_OVERLAY_VERSION not set (declare ARG and pass --build-arg)}"

PLATFORM_SPEC="${TARGETARCH:?TARGETARCH not set (declare ARG TARGETARCH)}${TARGETVARIANT:+/$TARGETVARIANT}"
case "${PLATFORM_SPEC}" in
    "amd64")  S6_ARCH="x86_64"  ;;
    "arm/v7") S6_ARCH="arm"     ;;
    "arm/v6") S6_ARCH="armhf"   ;;
    # Some buildah versions report the arm64 variant, some leave it empty.
    "arm64"|"arm64/v8") S6_ARCH="aarch64" ;;
    *) echo "Unsupported architecture: ${PLATFORM_SPEC}" >&2; exit 1 ;;
esac

url="https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}"
mkdir -p "$DEST"
curl -L -f -s --retry 3 "${url}/s6-overlay-noarch.tar.xz"      | tar Jxf - -C "$DEST"
curl -L -f -s --retry 3 "${url}/s6-overlay-${S6_ARCH}.tar.xz"  | tar Jxf - -C "$DEST"
