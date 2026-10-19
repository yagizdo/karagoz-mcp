#!/bin/sh
# Signs a Probe.app built by build.sh with "iphoneos" for the iPhone with UDID $2, for the iPhone smokes: with a
# provisioning profile Xcode keeps that covers dev.karagoz.probe (a team wildcard, or Probe's own id), has not expired,
# lists the phone and names an identity in this keychain. Exit 2 when no profile fits (the caller prints SKIP).
set -e
app=$1 phone=$2
[ -d "$app" ] && [ -n "$phone" ] || { echo "FAIL: sign.sh needs a Probe.app and a UDID"; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
profile= identity= team=
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for f in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"/*.mobileprovision; do
  [ -f "$f" ] && /usr/bin/security cms -D -i "$f" -o "$tmp/profile.plist" 2> /dev/null || continue
  t=$(/usr/bin/plutil -extract TeamIdentifier.0 raw "$tmp/profile.plist" 2> /dev/null) || continue
  case "$(/usr/bin/plutil -extract Entitlements.application-identifier raw "$tmp/profile.plist" 2> /dev/null)" in
    "$t.*" | "$t.dev.karagoz.probe") ;;
    *) continue ;;
  esac
  expr "$(/usr/bin/plutil -extract ExpirationDate raw "$tmp/profile.plist")" \> "$now" > /dev/null || continue
  /usr/bin/plutil -extract ProvisionedDevices json -o - "$tmp/profile.plist" 2> /dev/null | /usr/bin/grep -qi "\"$phone\"" || continue
  i=0
  while c=$(/usr/bin/plutil -extract "DeveloperCertificates.$i" raw "$tmp/profile.plist" 2> /dev/null); do
    sha=$(printf '%s' "$c" | /usr/bin/base64 -D | /usr/bin/shasum -a 1 | /usr/bin/cut -c1-40 | /usr/bin/tr a-f A-F)
    if /usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -q " $sha "; then profile=$f identity=$sha team=$t; fi
    i=$((i + 1))
  done
done
[ -n "$profile" ] || exit 2
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
  "<plist version=\"1.0\"><dict><key>application-identifier</key><string>$team.dev.karagoz.probe</string>" \
  "<key>com.apple.developer.team-identifier</key><string>$team</string><key>get-task-allow</key><true/></dict></plist>" \
  > "$tmp/probe.entitlements"
cp "$profile" "$app/embedded.mobileprovision"
/usr/bin/codesign --force --sign "$identity" --entitlements "$tmp/probe.entitlements" --timestamp=none "$app" 2> /dev/null ||
  { echo "FAIL: codesign could not sign Probe"; exit 1; }
