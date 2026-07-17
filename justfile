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
    # Transfer once and re-point `latest` on the remote side. save|load
    # instead of image scp: podman's builtin ssh client doesn't read
    # ~/.ssh/config, so the `rpi` alias doesn't resolve for it.
    podman save otbr-armv6:"${GIT_COMMIT}" | ssh rpi podman load
    ssh rpi podman tag otbr-armv6:"${GIT_COMMIT}" otbr-armv6:latest
    scp compose.yml otbr.env rpi:/root/otbr/
    echo "OTBR_TAG=${GIT_COMMIT}" | ssh rpi 'cat > /root/otbr/.env'
    ssh rpi 'cd /root/otbr && podman-compose up -d'
    ssh rpi podman image prune -f
