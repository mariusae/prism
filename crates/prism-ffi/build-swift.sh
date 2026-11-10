#!/bin/sh
# Builds the engine for Swift, generates the bindings, and runs the Swift
# test against them.
#
#   crates/prism-ffi/build-swift.sh            # debug
#   PROFILE=release crates/prism-ffi/build-swift.sh
#
# Leaves, in crates/prism-ffi/swift/Generated:
#   prism_ffi.swift            the Swift API
#   prism_ffiFFI.h             the C header under it
#   prism_ffiFFI.modulemap     its module map
# and the library in target/<profile>/: libprism_ffi.dylib and libprism_ffi.a.
set -eu
cd "$(dirname "$0")/../.."
PROFILE="${PROFILE:-debug}"
FLAG=""; [ "$PROFILE" = release ] && FLAG="--release"
OUT=crates/prism-ffi/swift/Generated
LIB="target/$PROFILE"

cargo build -p prism-ffi $FLAG
cargo run -q -p prism-ffi --bin uniffi-bindgen -- generate --library "$LIB/libprism_ffi.dylib" --language swift --out-dir "$OUT"

swiftc -swift-version 5 -o "$LIB/prism-ffi-swift-test" \
    -I "$OUT" -Xcc "-fmodule-map-file=$OUT/prism_ffiFFI.modulemap" \
    -L "$LIB" -lprism_ffi \
    "$OUT/prism_ffi.swift" crates/prism-ffi/swift/Tests/main.swift
DYLD_LIBRARY_PATH="$LIB" "$LIB/prism-ffi-swift-test"
