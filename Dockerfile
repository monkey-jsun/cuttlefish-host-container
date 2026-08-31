# Cuttlefish host container using launch_cvd
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TERM=xterm-256color

# Optional Ubuntu ports mirror override. Pass
# --build-arg APT_MIRROR=<host>[/<path>] (no scheme) to redirect apt when
# ports.ubuntu.com is slow or blocked. The rewrite leaves ubuntu.sources'
# URL scheme untouched (http by default), so it applies before
# ca-certificates lands; apt's GPG-signed InRelease covers integrity.
# Empty default is a no-op.
ARG APT_MIRROR=
RUN if [ -n "${APT_MIRROR}" ]; then \
      sed -Ei "s|ports\.ubuntu\.com(/ubuntu-ports)?|${APT_MIRROR}|g" \
        /etc/apt/sources.list.d/ubuntu.sources; \
    fi

# ---- Base OS deps ----
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    file \
    gnupg \
    unzip \
    iproute2 \
    iptables \
    iputils-ping \
    net-tools \
    dnsmasq-base \
    socat \
    python3 \
    python3-aiohttp \
    openssl \
    && rm -rf /var/lib/apt/lists/*

# ---- install qemu dependencies ----
# Kept above the cuttlefish-base layer so base.deb version bumps don't
# invalidate this layer. Only the guest architectures cuttlefish targets are
# installed; the qemu-system metapackage pulls an emulator for every
# architecture Debian ships.
RUN apt-get update && apt-get install -y --no-install-recommends \
    qemu-system-misc \
    qemu-system-x86 \
    qemu-system-arm \
    libpulse0 \
    libasound2t64 \
    libgbm1 \
    && rm -rf /var/lib/apt/lists/*

# --- Install cuttlefish-base (and cuttlefish-user on apt path).
# Default for amd64/arm64 is the official apt repo. riscv64 has no upstream
# apt repo; it pulls a pinned .deb from the fork's GitHub releases instead.
ARG CF_VERSION=1.54.0
ARG CF_RISCV64_VERSION=1.54.0
ARG CF_RISCV64_TAG=cf-k3-v1.1
ARG CF_LOCAL_BASE_DEB=.cuttlefish-base.placeholder
COPY ${CF_LOCAL_BASE_DEB} /tmp/cuttlefish-base.local.deb
RUN ARCH=$(dpkg --print-architecture) && \
    if [ -s /tmp/cuttlefish-base.local.deb ]; then \
      apt-get update \
      && apt-get install -y --no-install-recommends /tmp/cuttlefish-base.local.deb; \
    elif [ "$ARCH" != "riscv64" ]; then \
      curl -fsSL https://us-apt.pkg.dev/doc/repo-signing-key.gpg \
        -o /etc/apt/trusted.gpg.d/artifact-registry.asc \
      && chmod a+r /etc/apt/trusted.gpg.d/artifact-registry.asc \
      && echo "deb https://us-apt.pkg.dev/projects/android-cuttlefish-artifacts android-cuttlefish main" \
         > /etc/apt/sources.list.d/android-cuttlefish.list \
      && apt-get update && apt-get install -y --no-install-recommends \
           cuttlefish-base=${CF_VERSION} \
           cuttlefish-user=${CF_VERSION}; \
    else \
      curl -fsSL -o /tmp/cuttlefish-base.deb \
        https://github.com/monkey-jsun/android-cuttlefish/releases/download/${CF_RISCV64_TAG}/cuttlefish-base_${CF_RISCV64_VERSION}_${ARCH}.deb \
      && apt-get update \
      && apt-get install -y --no-install-recommends /tmp/cuttlefish-base.deb \
      && rm -f /tmp/cuttlefish-base.deb; \
    fi \
    && rm -f /tmp/cuttlefish-base.local.deb \
    && rm -rf /var/lib/apt/lists/*

# cuttlefish-base ships libgfxstream_backend.so at /usr/lib/cuttlefish-common/bin,
# outside the default linker search path. crosvm built with the gfxstream feature
# has it as DT_NEEDED and would exit at startup otherwise.
RUN echo "/usr/lib/cuttlefish-common/bin" > /etc/ld.so.conf.d/cuttlefish-common.conf \
    && ldconfig

# ---- Runtime layout ----
WORKDIR /cf

# ---- Entrypoint ----
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY webrtc_operator_shim.py /usr/local/bin/webrtc_operator_shim.py
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/webrtc_operator_shim.py

# Sources entrypoint.sh fetches from when /cf/host or /cf/product is empty.
# Empty unless cf-build.sh was given -H / -P.
ARG CF_HOST_PACKAGE_URL=
ARG CF_PRODUCT_IMG_URL=
ENV CF_HOST_PACKAGE_URL=${CF_HOST_PACKAGE_URL} \
    CF_PRODUCT_IMG_URL=${CF_PRODUCT_IMG_URL}

# WebRTC signaling (instance 1) + VNC (instance 1) + ADB TCP (instance 1)
EXPOSE 8443 5900 6520
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
