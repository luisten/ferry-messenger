#!/bin/sh
# Installs the latest release of Ferry Messenger, built from source as Release, on your paired iPhone
# (docs/DEVELOPMENT.md "Install on your iPhone"). Your checkout stays where it is: the release tag is built in a git
# worktree under build/update-iphone/. Needs Xcode, Config/Local.xcconfig and the phone paired; fetches Go if needed.
#   scripts/update-iphone.sh [--device <id>] [--no-install]
# --device: one of `xcrun devicectl list devices` when several iPhones are paired. --no-install: stop after the build.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
work=$root/build/update-iphone
src=$work/src
cache=$HOME/Library/Caches/ferry-messenger
device='' install=1
while [ $# -gt 0 ]; do
  case $1 in
    --device) device=${2:?--device needs an identifier}; shift 2 ;;
    --no-install) install=; shift ;;
    *) echo "usage: scripts/update-iphone.sh [--device <id>] [--no-install]" >&2; exit 2 ;;
  esac
done
die() { echo "update-iphone: $*" >&2; exit 1; }
[ -f "$root/Config/Local.xcconfig" ] ||
  die "Config/Local.xcconfig is missing: copy Config/Local.example.xcconfig and fill in your team ID and bundle prefix."

mkdir -p "$work"
epoch() { date -j -u -f %Y-%m-%dT%H:%M:%SZ "$1" +%s; }  # a plist date (UTC)

# The phone first, so a missing one stops us before a long build: the only paired physical iPhone, or --device.
if [ -n "$install" ] && [ -z "$device" ]; then
  xcrun devicectl list devices --json-output "$work/devices.json" >/dev/null
  get() { plutil -extract "result.devices.$i.$1" raw -o - "$work/devices.json" 2>/dev/null || true; }
  found=
  i=0
  while [ "$i" -lt "$(plutil -extract result.devices raw -o - "$work/devices.json")" ]; do
    if [ "$(get hardwareProperties.deviceType)" = iPhone ] && [ "$(get hardwareProperties.reality)" = physical ] &&
      [ "$(get connectionProperties.pairingState)" = paired ]; then
      found="$found $(get identifier)"
    fi
    i=$((i + 1))
  done
  # shellcheck disable=SC2086 # one word per identifier
  set -- $found
  [ $# -gt 0 ] || die "no paired iPhone: connect it to this Mac and trust it."
  [ $# -eq 1 ] || die "several paired iPhones ($found ): pick one with --device <id>."
  device=$1
fi
# Reachable now, by cable or on this Mac's network (a real connection, ~2 s): an away or asleep phone stops us here,
# not after the build.
if [ -n "$install" ]; then
  xcrun devicectl device info details --device "$device" --timeout 20 >/dev/null 2>&1 ||
    die "can't reach your iPhone: connect it by cable or join this Mac's Wi-Fi, unlock it, and run this again."
fi

# The newest release: a v* tag without "-".
git -C "$root" fetch -q --tags origin
tag=$(git -C "$root" tag -l 'v*' --sort=-version:refname | grep -v -- - | head -1)
[ -n "$tag" ] || die "no release tag found."
echo "Building Ferry Messenger $tag"
git -C "$root" worktree prune
if [ -e "$src/.git" ]; then
  git -C "$src" checkout -q --force --detach "$tag"
else
  git -C "$root" worktree add -q --detach "$src" "$tag"
fi
cp "$root/Config/Local.xcconfig" "$src/Config/"

# Go: the version core/build.sh pins, with the SHA-256 release.yml checks it against. Never Homebrew's.
want=$(sed -n 's/^want=//p' "$src/core/build.sh")
if [ "$(GOTOOLCHAIN=local go env GOVERSION 2>/dev/null || true)" != "$want" ]; then
  if [ ! -x "$cache/$want/go/bin/go" ]; then
    [ "$(sed -n 's/^ *GO_VERSION: //p' "$src/.github/workflows/release.yml")" = "$want" ] ||
      die "release.yml's GO_VERSION isn't core/build.sh's $want."
    sum=$(sed -n 's/^ *GO_SHA256: \([0-9a-f]*\).*/\1/p' "$src/.github/workflows/release.yml")
    echo "Downloading $want"
    rm -rf "${cache:?}/${want:?}" && mkdir -p "$cache/$want"
    curl -fsSLo "$cache/$want/go.tar.gz" "https://go.dev/dl/$want.darwin-arm64.tar.gz"
    printf '%s  %s\n' "$sum" "$cache/$want/go.tar.gz" | shasum -a 256 -c - >/dev/null || die "$want's checksum doesn't match."
    tar -xzf "$cache/$want/go.tar.gz" -C "$cache/$want" && rm "$cache/$want/go.tar.gz"
  fi
  PATH=$cache/$want/go/bin:$PATH
  export PATH
fi
"$src/core/build.sh" --check 2>/dev/null || "$src/core/build.sh"

# ponytail: untested on a free account. With one, Xcode keeps signing with its 7-day profile while it's still valid
# (seen on this Mac with a paid one), so a build on its last days would stop opening soon after. Under 3 days left,
# move it aside and Xcode issues a fresh one.
prefix=$(sed -n 's/^ *FERRY_BUNDLE_PREFIX *= *\([^ ]*\).*/\1/p' "$src/Config/Local.xcconfig" | tail -1)
profiles="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
for profile in "$profiles"/*.mobileprovision; do
  [ -f "$profile" ] || continue
  plist=$work/profile.plist
  security cms -D -i "$profile" -o "$plist" 2>/dev/null || continue
  id=$(plutil -extract Entitlements.application-identifier raw -o - "$plist" 2>/dev/null || true)
  managed=$(plutil -extract IsXcodeManaged raw -o - "$plist" 2>/dev/null || true)
  expires=$(epoch "$(plutil -extract ExpirationDate raw -o - "$plist")")
  if [ "${id#*.}" = "$prefix.ferry-messenger" ] && [ "$managed" = true ] && [ "$expires" -lt $(($(date +%s) + 3 * 86400)) ]; then
    mkdir -p "$cache/old-profiles" && mv "$profile" "$cache/old-profiles/"
    echo "Moved aside a profile that expires within 3 days: $(basename "$profile")"
  fi
done
rm -f "$work/profile.plist"

xcodebuild -project "$src/Ferry.xcodeproj" -scheme Ferry -configuration Release -destination generic/platform=iOS \
  -allowProvisioningUpdates -derivedDataPath "$work/DerivedData" -quiet build
app=$work/DerivedData/Build/Products/Release-iphoneos/Ferry.app
[ -d "$app" ] || die "no Release build at $app."
[ ! -e "$app/Ferry.debug.dylib" ] || die "the build has Ferry.debug.dylib: not an optimised Release build."
! grep -q FERRY_DEBUG_DEMO "$app/Ferry" || die "the build has DEBUG switches in it: not a Release build."

version=$(plutil -extract CFBundleShortVersionString raw -o - "$app/Info.plist")
security cms -D -i "$app/embedded.mobileprovision" -o "$work/profile.plist"
expiry=$(date -r "$(epoch "$(plutil -extract ExpirationDate raw -o - "$work/profile.plist")")" '+%-d %b %Y, %H:%M')
rm -f "$work/profile.plist"
if [ -n "$install" ]; then
  xcrun devicectl device install app --device "$device" "$app"
  echo "Installed Ferry Messenger $version on your iPhone. It opens until $expiry."
else
  echo "Built Ferry Messenger $version (not installed): $app. It would open until $expiry."
fi
