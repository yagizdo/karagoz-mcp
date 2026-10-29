#!/bin/sh
# Builds text-helper.jar next to this script from TextHelper.java: one classes.dex, karagoz's own code only. The jar is
# committed because users have no Android build tools; run this after changing the Java source and commit both.
# Needs a JDK (JAVA_HOME or javac on PATH) and an Android SDK with build-tools (d8) and a platform (android.jar,
# compile only, not shipped). Missing tools fail with what is missing and where it looked.
set -e
here=$(cd "$(dirname "$0")" && pwd)

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
[ -n "$bt" ] && [ -x "$sdk/build-tools/$bt/d8" ] || { echo "FAIL: no build-tools x.y.z with d8 in $sdk/build-tools"; exit 1; }
# API 37 ships only as android-37.0, .1 and .2.
api=$(ls "$sdk/platforms" | sed -n 's/^android-\([0-9][0-9]*\(\.[0-9][0-9]*\)\{0,1\}\)$/\1/p' | sort -t. -k1,1n -k2,2n | tail -n 1)
jar=$sdk/platforms/android-$api/android.jar
[ -n "$api" ] && [ -f "$jar" ] || { echo "FAIL: no platforms/android-N/android.jar in $sdk/platforms"; exit 1; }
javac=javac
[ -z "$JAVA_HOME" ] || javac=$JAVA_HOME/bin/javac
command -v "$javac" >/dev/null || { echo "FAIL: no javac (set JAVA_HOME to a JDK or put javac on PATH)"; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# Java 11 bytecode and min API 26: the oldest Android the helper runs on (Android 8.0).
"$javac" --release 11 -nowarn -classpath "$jar" -d "$tmp/classes" "$here/TextHelper.java"
"$sdk/build-tools/$bt/d8" --release --min-api 26 --lib "$jar" --output "$tmp/text-helper.jar" "$tmp/classes"/*.class
mv "$tmp/text-helper.jar" "$here/text-helper.jar"
echo "built $here/text-helper.jar ($(wc -c < "$here/text-helper.jar" | tr -d ' ') bytes, build-tools $bt, android-$api)"
