# Cuttlefish host container for RISC-V host
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TERM=xterm-256color

# ---- Base OS deps ----
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    unzip \
    iproute2 \
    iptables \
    iputils-ping \
    net-tools \
    dnsmasq-base \
    socat \
    && rm -rf /var/lib/apt/lists/*

# ---- install qemu dependencies ----
RUN apt-get update && apt-get install -y --no-install-recommends \
    qemu-system \
    libpulse0 \
    libasound2t64 \
    libgbm1 \
    && rm -rf /var/lib/apt/lists/*

# ---- install gpu accel related ----
# TODO: not working yet ...
RUN apt-get update && apt-get install -y --no-install-recommends \
    mesa-utils \
    mesa-vulkan-drivers \
    libgl1-mesa-dri \
    libegl1 \
    && rm -rf /var/lib/apt/lists/*

# --- Install cuttlefish-base deb from GitHub release ---
ARG CF_VERSION=1.50.0
ARG CF_TAG=v${CF_VERSION}-riscv64-260506
RUN curl -fsSL -o /tmp/cuttlefish-base.deb \
      https://github.com/monkey-jsun/android-cuttlefish/releases/download/${CF_TAG}/cuttlefish-base_${CF_VERSION}_riscv64.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends /tmp/cuttlefish-base.deb \
    && rm -f /tmp/cuttlefish-base.deb \
    && rm -rf /var/lib/apt/lists/*

# ---- WebRTC operator shim deps ----
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-aiohttp openssl \
    && rm -rf /var/lib/apt/lists/*

# ---- Runtime layout ----
WORKDIR /cf

# ---- Entrypoint + operator shim ----
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY operator_shim.py /usr/local/bin/operator_shim.py
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/operator_shim.py

# VNC (instance 1) + ADB TCP (instance 1)
EXPOSE 5900 6520
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
