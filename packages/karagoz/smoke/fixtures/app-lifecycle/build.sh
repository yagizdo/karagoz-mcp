#!/bin/sh
# Builds the smoke test APK into $1 from the manifest next to this script, for smokes 1.5 and 2.5: smoke.apk
# (versionCode 1) and smoke-v2.apk (versionCode 2) under one throwaway key, and bad.apk, one byte that is not an APK.
# Manifest only, no code (K28). Missing tools fail with what is missing and where it looked.
set -e
out=$1
[ -d "$out" ] || { echo "FAIL: build.sh needs an output directory"; exit 1; }
manifest=$(dirname "$0")/AndroidManifest.xml

# The newest build-tools and platform on this machine; no version is pinned here.
sdk=
looked=
for dir in "$ANDROID_HOME" "$ANDROID_SDK_ROOT" "$HOME/Library/Android/sdk" "$HOME/Android/Sdk"; do
  [ -n "$dir" ] || continue
  if [ -d "$dir/build-tools" ] && [ -d "$dir/platforms" ]; then sdk=$dir; break; fi
  looked="$looked $dir"
done
[ -n "$sdk" ] || { echo "FAIL: no Android SDK with build-tools/ and platforms/ (looked in:$looked)"; exit 1; }
# sort -V ranks 37.0.0-rc1 above 37.0.0, so only x.y.z names, sorted by number.
bt=$(ls "$sdk/build-tools" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)
[ -n "$bt" ] && [ -x "$sdk/build-tools/$bt/aapt2" ] && [ -x "$sdk/build-tools/$bt/apksigner" ] \
  || { echo "FAIL: no build-tools x.y.z with aapt2 and apksigner in $sdk/build-tools"; exit 1; }
bt=$sdk/build-tools/$bt
# API 37 ships only as android-37.0, .1 and .2.
api=$(ls "$sdk/platforms" | sed -n 's/^android-\([0-9][0-9]*\(\.[0-9][0-9]*\)\{0,1\}\)$/\1/p' | sort -t. -k1,1n -k2,2n | tail -n 1)
[ -n "$api" ] && [ -f "$sdk/platforms/android-$api/android.jar" ] \
  || { echo "FAIL: no platforms/android-N/android.jar in $sdk/platforms"; exit 1; }
command -v java >/dev/null || { echo "FAIL: java is not on PATH; apksigner runs it"; exit 1; }
command -v keytool >/dev/null || { echo "FAIL: keytool is not on PATH; it comes with the JDK"; exit 1; }

keytool -genkeypair -keystore "$out/k.jks" -storepass android -keypass android -alias k -keyalg RSA -keysize 2048 \
  -validity 1 -dname CN=karagoz-smoke >/dev/null 2>&1 || { echo "FAIL: keytool failed"; exit 1; }
# Without --v4-signing-enabled false apksigner writes an .idsig, and adb installs incrementally next to one.
# apksigner's stderr holds JDK 24+ warnings; its exit code decides.
for vc in 1 2; do
  "$bt/aapt2" link -o "$out/u.apk" -I "$sdk/platforms/android-$api/android.jar" --manifest "$manifest" \
    --min-sdk-version 24 --target-sdk-version "${api%%.*}" --version-code "$vc" || { echo "FAIL: aapt2 failed"; exit 1; }
  name=smoke.apk
  [ "$vc" = 1 ] || name=smoke-v$vc.apk
  "$bt/apksigner" sign --ks "$out/k.jks" --ks-pass pass:android --v4-signing-enabled false --out "$out/$name" \
    "$out/u.apk" 2>/dev/null || { echo "FAIL: apksigner failed"; exit 1; }
done
rm -f "$out/u.apk"
printf x > "$out/bad.apk"
