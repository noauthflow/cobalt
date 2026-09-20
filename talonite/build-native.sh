#!/bin/sh
# compiles the native helpers (swift/) into universal binaries under
# assets/compiled_raycast_swift/ — the same folder raycast's own swift
# packaging would produce, so src/native.ts can spawn them either way.
set -eu
cd "$(dirname "$0")"

OUT=assets/compiled_raycast_swift
mkdir -p "$OUT"

for name in color-picker Ruler audio bluetooth; do
  echo "building $name"
  swiftc -O \
    -target arm64-apple-macos13 \
    "swift/$name.swift" \
    -o "$OUT/$name.arm64"
  swiftc -O \
    -target x86_64-apple-macos13 \
    "swift/$name.swift" \
    -o "$OUT/$name.x86_64"
  lipo -create "$OUT/$name.arm64" "$OUT/$name.x86_64" -output "$OUT/$name"
  rm "$OUT/$name.arm64" "$OUT/$name.x86_64"
  codesign --force --sign - "$OUT/$name"
done

echo "done"