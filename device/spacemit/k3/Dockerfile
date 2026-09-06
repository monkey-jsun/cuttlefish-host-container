# Cuttlefish host container for SpaceMiT K3 with PowerVR GPU acceleration.
#
# gfxstream-gl path (A1.3): the guest renders through host GLES, which reaches
# the PowerVR BXM-4-64 GLES driver. This is the GPU-accelerated variant; the
# generic ../../../Dockerfile stays on stock ubuntu and falls back to
# guest_swiftshader.
#
# The base is not on Docker Hub; import the SpaceMiT rootfs tarball first.
# Note the tag says 24.04 but the contents are 24.04.1 -- that is what the
# image on k3-jun actually is, confirmed by diff_id, so the tag is kept and
# the version is recorded here rather than silently changing it:
#
#   URL    https://archive.spacemit.com/bianbu-base/bianbu-base-24.04.1-base-riscv64.tar.gz
#   sha256 a3f8ca97d8c399c05f8284adad8cc26980e3b7fe63e85026396d29174a9a554c
#
#   wget https://archive.spacemit.com/bianbu-base/bianbu-base-24.04.1-base-riscv64.tar.gz
#   echo "a3f8ca97d8c399c05f8284adad8cc26980e3b7fe63e85026396d29174a9a554c  bianbu-base-24.04.1-base-riscv64.tar.gz" | sha256sum -c
#   docker import bianbu-base-24.04.1-base-riscv64.tar.gz bianbu:24.04
#
# Built on bianbu (not the generic ubuntu base) because bianbu4's apt archive
# ships the proprietary Imagination userspace (img-gpu-powervr) the GPU path
# needs. Build with: cf-build.sh --device spacemit/k3
FROM bianbu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TERM=xterm-256color

# The bianbu:24.04 base tarball pins apt to bianbu/noble/snapshots/v2.2,
# which ships an older img-gpu-powervr build (bb3) that mismatches the current
# pvrsrvkm module ABI. Point apt at the bianbu4 archive on the resolute
# rolling suite so PVR userspace tracks the kernel module.
RUN sed -i -E \
      -e "s|^URIs:.*|URIs: https://archive.spacemit.com/bianbu4/|" \
      -e "s|^Suites:.*|Suites: resolute resolute-security resolute-updates resolute-backports resolute-porting resolute-customization|" \
      /etc/apt/sources.list.d/*.sources

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
# invalidate this layer. qemu-system stays for the qemu_cli path until
# cvd-host packages start bundling a per-arch qemu binary.
RUN apt-get update && apt-get install -y --no-install-recommends \
    qemu-system \
    libpulse0 \
    libasound2t64 \
    libgbm1 \
    && rm -rf /var/lib/apt/lists/*

# ---- K3 GPU userspace: PowerVR proprietary stack + GLVND + Vulkan loader ----
# gfxstream_graphics_detector requires host-side EGL/GLES + Vulkan to promote
# gpu_mode past guest_swiftshader. img-gpu-powervr ships libVK_IMG.so,
# libGLESv{1,2}_PVR_MESA.so, and powervr_icd.json; mesa-vulkan-drivers gives
# lavapipe as a software Vulkan fallback for cases where PVR init fails.
# PVR userspace must match the pvrsrvkm built into the kernel you boot.
# k3-jun runs 6.18.3-cf-k3-1.1, whose module is bb22; installing the archive's
# current bb25 against it makes vkCreateInstance fail with -3 and the loader
# report "no drivers".  Bump this and the kernel together, never separately.
ARG PVR_VERSION=24.2-6603887bb22
RUN apt-get update && apt-get install -y --no-install-recommends \
    img-gpu-powervr=${PVR_VERSION} \
    libvulkan1 \
    libvirglrenderer1 \
    libglvnd0 \
    libgl1 \
    libgles1 \
    libgles2 \
    libegl1 \
    mesa-utils \
    && rm -rf /var/lib/apt/lists/*

# ---- PowerVR GL/DRI path: Bianbu's Mesa fork (24.01bb5) ----
# gfxstream-gl reaches the PowerVR GLES driver through Mesa's pvr_dri.so, which
# exists only in Bianbu's 24.01bb5 Mesa fork. That fork is no longer in any apt
# suite (bianbu4 now serves stock Mesa 26 without it), so fetch the five debs
# from the asset-host release and verify each by sha256 before installing.
# Install via apt (not dpkg -i): the fork debs pull ordinary repo deps
# (libwayland-server0, libxcb-dri2-0, libdrm-radeon1, libxfixes3) that dpkg
# cannot fetch, and apt keeps the explicitly-named local files at 24.01bb5
# rather than substituting the stock 26 versions. --allow-downgrades because
# the layer above already pulled in stock 26. Hold them so a later apt upgrade
# can't pull the fork back out.
ARG MESA_PVR_BASE=https://github.com/monkey-jsun/aosp-cuttlefish-riscv64/releases/download/mesa-pvr-24.01bb5
RUN set -eu; cd /tmp; \
    for e in \
      "f32101a3643c1a0b309a9b3d0788d5c95e2d4f682081331b0466c6b8a7410bc2  libegl-mesa0_24.01bb5_riscv64.deb" \
      "0e2857223201ff20560135351846881c36b0429b3de9b92b126bf3b88d4ac6a9  libgbm1_24.01bb5_riscv64.deb" \
      "431b8839fb1834100595ca4e063bb9a3e1df6140f5c86afac476b7a17f5bc30b  libgl1-mesa-dri_24.01bb5_riscv64.deb" \
      "4ff98de5108d882a1483c86d7a54c761d49e61d71281e765ca176a813010244d  libglapi-mesa_24.01bb5_riscv64.deb" \
      "d74136b46e37840addd28b988268b5f69b7883f3f0688f06878b09c2d99434c0  libglx-mesa0_24.01bb5_riscv64.deb" \
    ; do \
      f="${e##*  }"; \
      curl -fL -o "$f" "$MESA_PVR_BASE/$f"; \
      echo "$e" | sha256sum -c -; \
    done; \
    apt-get update; \
    apt-get install -y --no-install-recommends --allow-downgrades \
      ./libegl-mesa0_24.01bb5_riscv64.deb \
      ./libgbm1_24.01bb5_riscv64.deb \
      ./libgl1-mesa-dri_24.01bb5_riscv64.deb \
      ./libglapi-mesa_24.01bb5_riscv64.deb \
      ./libglx-mesa0_24.01bb5_riscv64.deb; \
    apt-mark hold libegl-mesa0 libgbm1 libgl1-mesa-dri libglapi-mesa libglx-mesa0; \
    rm -f /tmp/*.deb; \
    rm -rf /var/lib/apt/lists/*

# glvnd ships only versioned runtime sonames (libEGL.so.1, libGLESv2.so.2,
# libGLESv1_CM.so.1); the unversioned names normally come from the -dev
# packages. The gfxstream backend links the unversioned names, so add just
# those three symlinks.
RUN cd /usr/lib/riscv64-linux-gnu && \
    ln -sf libEGL.so.1       libEGL.so && \
    ln -sf libGLESv2.so.2    libGLESv2.so && \
    ln -sf libGLESv1_CM.so.1 libGLESv1_CM.so && \
    ldconfig

# --- Install cuttlefish-base.
# riscv64 has no upstream apt repo; pull a pinned .deb from the fork's GitHub
# releases when no local .deb is provided (via cf-build.sh -d).
ARG CF_RISCV64_VERSION=1.54.0
ARG CF_RISCV64_TAG=cf-k3-v1.1
ARG CF_LOCAL_BASE_DEB=.cuttlefish-base.placeholder
COPY ${CF_LOCAL_BASE_DEB} /tmp/cuttlefish-base.local.deb
RUN ARCH=$(dpkg --print-architecture) && \
    if [ -s /tmp/cuttlefish-base.local.deb ]; then \
      apt-get update \
      && apt-get install -y --no-install-recommends /tmp/cuttlefish-base.local.deb; \
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

# ---- GPU launch defaults ----
# gfxstream-gl reaches the PowerVR GLES driver through EGL's surfaceless
# platform (no X/GBM display in the container). Default the launch to
# --gpu_mode=gfxstream so 'cf-run.sh -i cf-host-spacemit-k3' needs no flag;
# entrypoint.sh reads CF_GPU_MODE.
ENV EGL_PLATFORM=surfaceless
ENV CF_GPU_MODE=gfxstream

# ---- Runtime layout ----
WORKDIR /cf

# ---- Entrypoint ----
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY webrtc_operator_shim.py /usr/local/bin/webrtc_operator_shim.py
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/webrtc_operator_shim.py

# WebRTC signaling (instance 1) + VNC (instance 1) + ADB TCP (instance 1)
EXPOSE 8443 5900 6520
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
