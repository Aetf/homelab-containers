GITHUB_REPO := "openthread/ot-br-posix"
GIT_BRANCH := "main"

# Fetch the latest commit hash for the specified branch
GIT_COMMIT := shell(f"git ls-remote https://github.com/{{GITHUB_REPO}}.git refs/heads/{{GIT_BRANCH}} | cut -f1")

deploy:
    podman build \
        --build-arg GIT_COMMIT={{GIT_COMMIT}} \
        -t otbr-armv6:{{GIT_COMMIT}} \
        -t otbr-armv6:latest \
        --platform linux/arm/v6 \
        --file Containerfile
    podman image scp otbr-armv6:{{GIT_COMMIT}} rpi::
    podman image scp otbr-armv6:latest rpi::
    scp compose.yml otbr.env rpi:/root/otbr/
