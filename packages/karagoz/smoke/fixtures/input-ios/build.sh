#!/bin/sh
# Builds Probe.app into $1 from Probe.swift and Info.plist next to this script, for the iOS smokes: for a simulator, or
# with "iphoneos" as $2 for a physical iPhone, unsigned (sign.sh signs it). The selected Xcode's own swiftc, not xcrun;
# the linker's ad-hoc signature is enough for a simulator. Missing tools fail with what is missing and where it looked.
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
platform=iPhoneSimulator
[ "$2" = iphoneos ] && platform=iPhoneOS
sdk=$dev/Platforms/$platform.platform/Developer/SDKs/$platform.sdk
[ -x "$swiftc" ] || { echo "FAIL: no swiftc at $swiftc"; exit 1; }
[ -d "$sdk" ] || { echo "FAIL: no $platform SDK at $sdk"; exit 1; }
[ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] && arch=arm64 || arch=x86_64
target=$arch-apple-ios26.0-simulator
[ $platform = iPhoneOS ] && target=arm64-apple-ios26.0

# iOS 26.0 so it installs on Xcode 26's runtimes too. swiftc records the target as the SDK version, and iOS 27 runs an
# app that claims SDK 17 scaled to 393x852 points on a 402x874 iPhone 17, so its tree no longer matches the screen.
mkdir -p "$out/Probe.app"
"$swiftc" -O -parse-as-library -target "$target" -sdk "$sdk" "$here/Probe.swift" \
  -o "$out/Probe.app/Probe" || { echo "FAIL: swiftc failed"; exit 1; }
cp "$here/Info.plist" "$out/Probe.app/Info.plist"
[ $platform = iPhoneSimulator ] || plutil -replace CFBundleSupportedPlatforms -json '["iPhoneOS"]' "$out/Probe.app/Info.plist"
