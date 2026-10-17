#!/bin/sh
# Builds core/ (cmd/igcore) as a static library for iOS devices and the simulator, then build/IGCore.xcframework.
# Needs Xcode and Go 1.27.1 on PATH (core/go.mod's toolchain line). No gomobile: Go's c-archive mode with Xcode's clang;
# the Go linker takes the platform (device or simulator) from the cgo objects.
set -eu
cd "$(dirname "$0")"

want=go1.27.1
have=$(go env GOVERSION)
[ "$have" = "$want" ] || { echo "core/build.sh: need $want on PATH, found $have" >&2; exit 1; }

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
echo "build/IGCore.xcframework"
