#!/bin/sh
# Builds core/ (cmd/igcore) as a static library for iOS devices and the simulator, then build/IGCore.xcframework.
# Needs Xcode and Go 1.27.3 on PATH (core/go.mod's toolchain line). No gomobile: Go's c-archive mode with Xcode's clang;
# the Go linker takes the platform (device or simulator) from the cgo objects.
set -eu
cd "$(dirname "$0")"

# What the library is built from: this script, go.mod, go.sum, cmd/igcore and every package outside cmd/ (no tests).
# Written into the xcframework; the app's "Check core/" build phase runs `core/build.sh --check`, so a pulled core/
# change stops the build with one message instead of Swift's errors about IGCore's functions.
stamp() {
  { printf '%s\n' build.sh go.mod go.sum
    find cmd/igcore . -path ./cmd -prune -o -name '*.go' ! -name '*_test.go' -print; } |
    LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256 | cut -c1-64
}
if [ "${1-}" = --check ]; then
  [ "$(cat ../build/IGCore.xcframework/core.sha256 2>/dev/null)" = "$(stamp)" ] && exit 0
  echo "error: build/IGCore.xcframework is missing or older than core/: run core/build.sh (Go 1.27.3 on PATH)" >&2
  exit 1
fi

want=go1.27.3
have=$(GOTOOLCHAIN=local go env GOVERSION)  # local: an older Go would otherwise fetch the toolchain line's by itself
[ "$have" = "$want" ] || { echo "core/build.sh: need $want on PATH, found $have" >&2; exit 1; }

sum=$(stamp)
out=../build/core
rm -rf "$out" ../build/IGCore.xcframework
for kind in device sim; do
  if [ "$kind" = device ]; then sdk=iphoneos; target=arm64-apple-ios26.0; else sdk=iphonesimulator; target=arm64-apple-ios26.0-simulator; fi
  flags="-isysroot $(xcrun --sdk "$sdk" --show-sdk-path) -target $target"
  mkdir -p "$out/$kind/include"
  CGO_ENABLED=1 GOOS=ios GOARCH=arm64 GOTOOLCHAIN=local \
    CC="$(xcrun --sdk "$sdk" -f clang) $flags" CGO_CFLAGS="$flags" CGO_LDFLAGS="$flags" \
    go build -trimpath -ldflags="-s -w" -buildmode=c-archive -o "$out/$kind/libigcore.a" ./cmd/igcore
  mv "$out/$kind/libigcore.h" "$out/$kind/include/"
  printf 'module IGCore {\n  header "libigcore.h"\n  export *\n}\n' >"$out/$kind/include/module.modulemap"  # `import IGCore`
done
xcodebuild -create-xcframework -output ../build/IGCore.xcframework \
  -library "$out/device/libigcore.a" -headers "$out/device/include" \
  -library "$out/sim/libigcore.a" -headers "$out/sim/include" >/dev/null
echo "$sum" >../build/IGCore.xcframework/core.sha256
echo "build/IGCore.xcframework"
