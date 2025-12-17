# cuttlefish-host-container
Docker container that runs Android cuttlefish emulators for x86_64, arm64, riscv64 guests

## Background
I simply wanted to run RISC-V AOSP via cuttlefish on my laptop, and the journey wasn't smooth.
* The [info](https://github.com/google/android-riscv64) is scarce, broken and conflicting
* My host machine ends up seriously "polluted" and cluttered by packages, virtual devices and run-time artifacts
* The [existing container-based solution by Google](https://source.android.com/docs/devices/cuttlefish/on-premises) is an overkill and not friendly at all

## Goal
Simple container that runs 1 cuttlefish instance inside on my x86_64 linux host.  Incidentally it can now run following guests:
1. x86 guest via crosvm
2. x86 guest via qemu
3. arm64 guest via qemu
4. riscv64 guest via qemu

## Usage
```
docker build . -t cf-host

./cf-init.sh -P aosp_cf_x86_64_only_phone-img-14421689.zip -H cvd-host_package.tar.gz

# run with qemu
./cf-run.sh
gvncviewer localhost

# or run with crosvm, much faster
./cf-run.sh -- -e CF_VM_MANAGER=crosvm -e CF_START_WEBRTC=true
firefox https://localhost:8443
```

You can find product img zip file and cvd host package from [Google aosp build artifacts site](https://ci.android.com/builds/branches/aosp-android-latest-release/grid?legacy=1).

Or [build them from your own aosp tree](https://source.android.com/docs/setup/build/building),
```
source build/envsetup.sh
lunch aosp_cf_x86_64_only_phone-aosp_current-userdebug
m dist
# those two packages can be found under $(ANDROID_ROOT)/out/dist/
```
Additional notes:
* run "cf-init.sh -h" and "cf-run.sh -h" for more info
* to create multiple containers/instances, create multiple directories.  For example, "mkdir riscv; cd riscv; ../cf-init.sh ....; ../cf-run.sh".
  * However, you can only run 1 of them currently due to port conflict.
* ADB, VNC ports are visiable to host LAN.  So you can run it on a headless server.

## TODO
* GPU acceleration does not work yet
