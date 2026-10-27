#!/bin/sh
# Builds the step 1 gate (docs/PLAN-relay.md) for Macs with either chip into build/relaygate/: relaygate (macOS 12+)
# and relaygate-login (macOS 13+, for Ferry's InstagramLogin.swift). Needs Go 1.27.3 on PATH, as core/build.sh does.
set -eu
cd "$(dirname "$0")"
out=../../../build/relaygate
rm -rf "$out"
mkdir -p "$out"
for arch in arm64 amd64; do
  CGO_ENABLED=0 GOOS=darwin GOARCH=$arch GOTOOLCHAIN=local go build -trimpath -ldflags="-s -w" -o "$out/relaygate.$arch" .
done
for arch in arm64 x86_64; do
  xcrun swiftc -O -swift-version 6 -target $arch-apple-macos13 -o "$out/relaygate-login.$arch" login/main.swift ../../../Ferry/InstagramLogin.swift
done
lipo -create -output "$out/relaygate" "$out/relaygate.arm64" "$out/relaygate.amd64"
lipo -create -output "$out/relaygate-login" "$out/relaygate-login.arm64" "$out/relaygate-login.x86_64"
rm "$out"/*.arm64 "$out"/*.amd64 "$out"/*.x86_64
codesign --force --sign - "$out/relaygate" "$out/relaygate-login"  # ad hoc: an Apple silicon Mac runs nothing unsigned
echo "$out: relaygate, relaygate-login"
