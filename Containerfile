ARG ALPINE_VERSION=3.23.0

FROM docker.io/alpine:${ALPINE_VERSION} AS builder

ARG GITHUB_REPO="openthread/ot-br-posix"
ARG GIT_COMMIT="refs/heads/main"

ENV S6_OVERLAY_VERSION=3.2.2.0
WORKDIR /work

RUN apk add build-base pkgconfig \
    && apk add curl wget ca-certificates \
    && apk add cmake git samurai \
    && apk add npm \
    && apk add protobuf-dev jsoncpp-dev cjson-dev

RUN git clone \
        --depth 1 \
        --recurse-submodules --shallow-submodules \
        --revision "${GIT_COMMIT}"\
        https://github.com/"${GITHUB_REPO}".git \
        src

RUN cmake -Bbuild -Ssrc \
        -GNinja \
        -Wno-dev \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DCMAKE_CXX_FLAGS="-Wno-psabi -DOPENTHREAD_CONFIG_MLE_DEFAULT_LEADER_WEIGHT_ADJUSTMENT=8" \
        -DBUILD_TESTING=OFF \
        -DOTBR_DBUS=OFF \
        -DOTBR_MDNS=openthread \
        -DOTBR_REST=ON \
        -DOTBR_WEB=ON \
        -DOT_POSIX_NAT64_CIDR="192.168.255.0/24" \
        -DOT_FIREWALL=ON \
    && cmake --build build \
    && DESTDIR=install cmake --install build

# Upstream rootfs assumes the mDNSResponder backend and unconditionally
# ships an s6 service exec'ing /usr/sbin/mdnsd; with OTBR_MDNS=openthread
# there is no mdnsd binary and the service crash-loops, flooding the log.
RUN cp -r src/etc/docker/border-router/rootfs/* install \
    && rm -rf install/etc/s6-overlay/s6-rc.d/mdns \
              install/etc/s6-overlay/s6-rc.d/user/contents.d/mdns \
              install/etc/s6-overlay/s6-rc.d/otbr-agent/dependencies.d/mdns

# Prepare S6 overlay source
ARG TARGETARCH
ARG TARGETVARIANT

RUN PLATFORM_SPEC="${TARGETARCH}${TARGETVARIANT:+/$TARGETVARIANT}" \
    && case "${PLATFORM_SPEC}" in \
         "amd64") S6_ARCH="x86_64" ;; \
         "arm/v7") S6_ARCH="arm" ;; \
         "arm/v6") S6_ARCH="armhf" ;; \
         "arm64") S6_ARCH="aarch64" ;; \
         *) echo "Unsupported architecture: ${PLATFORM_SPEC}"; exit 1 ;; \
       esac \
    && curl -L -f -s "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz" \
        | tar Jxvf - -C install/ \
    && curl -L -f -s "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${S6_ARCH}.tar.xz" \
        | tar Jxvf - -C install/

FROM docker.io/alpine:${ALPINE_VERSION}

ARG GITHUB_REPO="openthread/ot-br-posix"
ARG GIT_COMMIT
LABEL org.opencontainers.image.source="https://github.com/${GITHUB_REPO}"
LABEL org.opencontainers.image.revision="${GIT_COMMIT}"
ENV OTBR_COMMIT=${GIT_COMMIT}

RUN apk add bash uutils-coreutils ipset iptables \
    && apk add libprotobuf jsoncpp libedit cjson

COPY --from=builder /work/install/ /

COPY otbr-web-rootfs /

ENTRYPOINT ["/init"]
