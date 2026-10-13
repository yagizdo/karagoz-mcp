#!/bin/sh
# Builds Probe.app into $1 from Probe.swift and Info.plist next to this script, for smoke 3.4. The selected Xcode's own
# swiftc, not xcrun; iOS 17.0 as the floor so the app installs on older runtimes too; the linker's ad-hoc signature is
# enough for a simulator. Missing tools fail with what is missing and where it looked.
set -e
out=$1
[ -d "$out" ] || { echo "FAIL: build.sh needs an output directory"; exit 1; }
here=$(dirname "$0")

# The Xcode karagoz picks: DEVELOPER_DIR, else xcode-select's link, else the default install.
dev=$DEVELOPER_DIR
[ -n "$dev" ] || dev=$(readlink /var/db/xcode_select_link 2>/dev/null) || true
[ -n "$dev" ] || dev=/Applications/Xcode.app/Contents/Developer
case $dev in *.app | *.app/) dev=${dev%/}/Contents/Developer ;; esac
swiftc=$dev/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc
sdk=$dev/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk
[ -x "$swiftc" ] || { echo "FAIL: no swiftc at $swiftc"; exit 1; }
[ -d "$sdk" ] || { echo "FAIL: no iPhoneSimulator SDK at $sdk"; exit 1; }
[ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] && arch=arm64 || arch=x86_64

mkdir -p "$out/Probe.app"
"$swiftc" -O -parse-as-library -target "$arch-apple-ios17.0-simulator" -sdk "$sdk" "$here/Probe.swift" \
  -o "$out/Probe.app/Probe" || { echo "FAIL: swiftc failed"; exit 1; }
cp "$here/Info.plist" "$out/Probe.app/Info.plist"
