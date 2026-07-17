GITHUB_REPO := "openthread/ot-br-posix"
GIT_BRANCH := "main"

deploy:
    #!/usr/bin/env bash
    set -euo pipefail
    # Resolved here instead of a top-level shell() so `just --list`
    # doesn't hit the network.
    GIT_COMMIT=$(git ls-remote https://github.com/{{GITHUB_REPO}}.git refs/heads/{{GIT_BRANCH}} | cut -f1)
    podman build \
        --build-arg GIT_COMMIT="${GIT_COMMIT}" \
        -t otbr-armv6:"${GIT_COMMIT}" \
        -t otbr-armv6:latest \
        --platform linux/arm/v6 \
        --file Containerfile
    # Transfer once; image scp sends the full archive per invocation (no
    # layer dedup), so `latest` is re-pointed on the remote side instead.
    podman image scp otbr-armv6:"${GIT_COMMIT}" rpi::
    ssh rpi podman tag otbr-armv6:"${GIT_COMMIT}" otbr-armv6:latest
    scp compose.yml otbr.env rpi:/root/otbr/
    echo "OTBR_TAG=${GIT_COMMIT}" | ssh rpi 'cat > /root/otbr/.env'
    ssh rpi 'cd /root/otbr && podman-compose up -d'
    ssh rpi podman image prune -f
