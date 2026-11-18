#!/bin/sh
# Writes the AltStore source (also read by SideStore) for one release to stdout: the release workflow uploads it as
# source.json, which users add once from releases/latest/download/source.json (docs/DEVELOPMENT.md "Update to a new
# version"). Everything about the app comes from the built Ferry.app, so the source can't disagree with the .ipa:
# AltStore refuses an install whose version, bundle ID or usage descriptions differ from the source's.
#   scripts/make-source.sh <Ferry.app> <FerryMessenger.ipa> <tag> >source.json
set -eu
[ $# -eq 3 ] || { echo "usage: scripts/make-source.sh <Ferry.app> <FerryMessenger.ipa> <tag>" >&2; exit 2; }
app=$1 ipa=$2 tag=$3
repo=${GITHUB_REPOSITORY:-luisten/ferry-messenger}
info=$app/Info.plist
key() { plutil -extract "$1" raw -o - "$info"; }

version=$(key CFBundleShortVersionString)
[ "$version" = "${tag#v}" ] || { echo "make-source: the app is $version but the tag is $tag" >&2; exit 1; }
bundle=$(key CFBundleIdentifier)

# Every usage description the app declares (its top-level NS*UsageDescription keys), escaped for JSON by plutil.
privacy=$(mktemp)
trap 'rm -f "$privacy"' EXIT
plutil -create xml1 "$privacy"
for k in $(plutil -p "$info" | sed -n 's/^  "\(NS[A-Za-z]*UsageDescription\)" => .*/\1/p'); do
  plutil -insert "$k" -string "$(key "$k")" "$privacy"
done

cat <<EOF
{
  "name": "Ferry Messenger",
  "identifier": "$bundle.source",
  "website": "https://github.com/$repo",
  "apps": [{
    "name": "Ferry Messenger",
    "bundleIdentifier": "$bundle",
    "developerName": "${repo%%/*}",
    "subtitle": "Your Instagram messages and nothing else.",
    "localizedDescription": "An iPhone app for your Instagram direct messages and nothing else. All your Instagram accounts in one inbox, and no feed, no Explore, no algorithm. Unofficial: not affiliated with Instagram or Meta.",
    "iconURL": "https://raw.githubusercontent.com/$repo/$tag/Ferry/Assets.xcassets/AppIcon.appiconset/AppIcon.png",
    "versions": [{
      "version": "$version",
      "buildVersion": "$(key CFBundleVersion)",
      "date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
      "downloadURL": "https://github.com/$repo/releases/download/$tag/FerryMessenger.ipa",
      "size": $(stat -f %z "$ipa"),
      "sha256": "$(shasum -a 256 "$ipa" | cut -d' ' -f1)",
      "minOSVersion": "$(key MinimumOSVersion)",
      "localizedDescription": "What's new: https://github.com/$repo/releases/tag/$tag"
    }],
    "appPermissions": {
      "entitlements": [],
      "privacy": $(plutil -convert json -o - "$privacy")
    }
  }],
  "news": []
}
EOF
