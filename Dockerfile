# Cuttlefish host container using launch_cvd
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

# --- Add official Cuttlefish apt repo, install cuttlefish-base/user ---
RUN curl -fsSL https://us-apt.pkg.dev/doc/repo-signing-key.gpg \
      -o /etc/apt/trusted.gpg.d/artifact-registry.asc \
    && chmod a+r /etc/apt/trusted.gpg.d/artifact-registry.asc \
    && echo "deb https://us-apt.pkg.dev/projects/android-cuttlefish-artifacts android-cuttlefish main" \
       > /etc/apt/sources.list.d/android-cuttlefish.list \
    && apt-get update && apt-get install -y --no-install-recommends \
         cuttlefish-base \
         cuttlefish-user \
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

# ---- Runtime layout ----
WORKDIR /cf

# ---- Entrypoint ----
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# VNC (instance 1) + ADB TCP (instance 1)
EXPOSE 5900 6520
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
