# SpaceMiT K3 — PowerVR GPU-accelerated cuttlefish host

GPU-accelerated variant of the cuttlefish host container for the SpaceMiT K3
(PowerVR BXM-4-64). The guest renders through the host GLES stack
(`--gpu_mode=gfxstream`, "gfxstream-gl"), which reaches the PowerVR GLES driver.
The generic image (`../../../Dockerfile`) stays on stock ubuntu and falls back
to `guest_swiftshader`; this one adds the PowerVR userspace.

## Build

```sh
cf-build.sh --device spacemit/k3        # -> image cf-host-spacemit-k3
```

Prerequisite: import the bianbu base image once (see the header of `Dockerfile`).
The build fetches the PowerVR Mesa fork (24.01bb5) from a GitHub release and
verifies each deb by sha256; no local artifacts are needed.

## Run

```sh
cf-run.sh -i cf-host-spacemit-k3
```

`--gpu_mode=gfxstream` and `EGL_PLATFORM=surfaceless` are baked into the image,
so no GPU flags are needed at run time. The guest images and instance state are
identical to a swiftshader run, so the same `cf-data` works under either image;
boot clean (`-- --noresume`) when switching backends.

## Why the Mesa fork is fetched, not apt-installed

gfxstream-gl reaches the PowerVR GLES driver through Mesa's `pvr_dri.so`, which
exists only in Bianbu's 24.01bb5 Mesa fork. That fork is no longer in any apt
suite — bianbu4 now serves stock Mesa 26 without it — so the five debs are
hosted as an asset-only pre-release and fetched at build time:

    https://github.com/monkey-jsun/aosp-cuttlefish-riscv64/releases/tag/mesa-pvr-24.01bb5

## Kernel pairing

The PowerVR DDK userspace (`ARG PVR_VERSION`) must match the `pvrsrvkm` module
in the booted kernel. k3-jun runs `6.18.3-cf-k3-1.1` (module `bb22`), so
`PVR_VERSION=24.2-6603887bb22`. Bump the two together, never separately, or
`vkCreateInstance` fails with `-3` ("no drivers").

## Scope

gfxstream-gl (GLES) renders correctly. The Vulkan path (gfxstream-vk / ANGLE →
PowerVR Vulkan) is broken on this GPU and is out of scope for this image.
