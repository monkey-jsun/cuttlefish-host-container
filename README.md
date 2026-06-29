# cuttlefish-host-container
Docker container that runs Android cuttlefish emulators for x86_64, arm64, riscv64 guests

## Background
I started with a simple desire to run RISC-V AOSP cuttlefish image on my x86_64 laptop, and the journey wasn't smooth.
* The [info](https://github.com/google/android-riscv64) is scarce, broken and conflicting
* My host machine ended up seriously "polluted" and cluttered by packages, virtual devices and run-time artifacts
* The [existing container-based solution by Google](https://source.android.com/docs/devices/cuttlefish/on-premises) is an overkill and not friendly at all
* Fundamentally I realized that Android Cuttlefish was meant for cloud and infra usage, not for an individual on a laptop.

Thus this project was born.  And it expanded.

## Scope - features and constraints

* Simple container that runs 1 cuttlefish instance at a time
* Docker bridge networking keeps the host clean; published ports provide reachability and convenience
* Support all 3 arches of hosts, x86_64, arm64 and riscv64
* Support all 3 arches of guests, x86_64, arm64, and riscv64
* Support webrtc UI connection for crosvm and VNC UI connection for qemu
* Support adb connection

See host/guest support matrix below.
Same-arch host/guest defaults to crosvm (qemu selectable via flag); cross-arch is qemu only.

  | Host\Guest | x86_64 | arm64 | riscv64 |
  | -------- | ------- | ------- | ------- |
  | x86_64  | crosvm ✓<br>qemu ✓ | qemu ✓ | qemu ✓ |
  | arm64   | qemu ❓ | crosvm ⚠<br>qemu ❓ | qemu ❓ |
  | riscv64 | qemu ✗ | qemu ✗ | crosvm ✓<br>qemu ✗ |

  Legend: ✓ verified · ⚠ supported but unverified · ❓ unknown · ✗ unsupported

## Usage
4 steps to use the container:
1. build the docker image with "cf-build.sh" (once)
2. create or update the cvd instance with "cf-init.sh ..." (infrequently, as needed)
    1. populate/update instance with aosp img zip and/or cvd host package
3. run the cvd instance with "cf-run.sh" (frequently)
    1. connect to the instance via adb, vnc or webrtc
4. stop cvd instance with "cf-stop.sh"

Below is a sample execution sequence on x86_64 host.

```
./cf-build.sh

./cf-init.sh -P aosp_cf_x86_64_only_phone-img-14421689.zip -H cvd-host_package.tar.gz

# run with default crosvm
./cf-run.sh
firefox https://localhost:8443

# or run with qemu
./cf-run.sh --vm-manager qemu_cli
gvncviewer localhost

# connect via adb
adb connect localhost:6520
```

For x86_64 and arm64, you can find the AOSP image zip and cvd host package from [Google aosp build artifacts site](https://ci.android.com/builds/branches/aosp-android-latest-release/grid?legacy=1).
Or [build them from your own aosp tree](https://source.android.com/docs/setup/build/building),
```
source build/envsetup.sh
lunch aosp_cf_x86_64_only_phone-aosp_current-userdebug
m dist
# those two packages can be found under $(ANDROID_ROOT)/out/dist/
```

For RISCV64, refer to [the central github project, aosp-cuttlefish-riscv64](https://github.com/monkey-jsun/aosp-cuttlefish-riscv64/tree/main)

Additional notes:
* run "cf-build.sh -h", "cf-init.sh -h", "cf-run.sh -h", "cf-stop.sh -h" for more info
* to create multiple containers/instances, create multiple directories.  For example, "mkdir riscv; cd riscv; ../cf-init.sh ....; ../cf-run.sh".
  * However, you can only run 1 of them at any time due to port conflict.
* ADB, VNC ports are visible to host LAN.  So you can run it on a headless server.

## TODO
* GPU acceleration does not work yet

## Networking

Plain and standard docker bridge mode, no additional tun/tap/etc network interface pollution to the host.  Container reaches outbound via docker0 MASQUERADE; clients reach inbound via published host ports:

* `8443/tcp` — WebRTC HTTPS (crosvm path)
* `5900/tcp` — VNC (qemu path; in-container socat bridge from launch_cvd's `127.0.0.1:6444`)
* `6520/tcp` — adb
* `15550-15599/udp` — WebRTC ICE media (crosvm path)

VNC and adb bind `0.0.0.0`; reachable from anywhere on the host LAN.  VNC needs no further wiring — `gvncviewer <host>` works.

WebRTC needs more care:

1. cvd is pinned to UDP `15550-15599` via `--udp_port_range` (cf dialect) / `--webrtc_udp_port_range` (AOSP), forwarded 1:1 to the host.  Static DNAT, no STUN/TURN dependency — the browser sends UDP straight to `<host-ip>:15550-15599` and docker DNATs it into the container.
2. `cf-run.sh` auto-detects the host's outward IPv4 addresses (LAN, tailscale, VPN) and injects them as ICE host candidates, so the browser actually has a reachable address to try.
3. Override or disable with `--docker-arg "--env=CF_EXTRA_HOST_IPS=<csv>"` (empty = off; reasonable when both peers have public IPs and srflx hole-punching already works).

---
![Screenshot 2025-12-17 204158](https://github.com/user-attachments/assets/dff3fb6a-461b-440c-a323-85a6d6f9ad81)


