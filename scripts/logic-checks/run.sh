#!/bin/sh
# Compiles the app's pure logic files together with the checks and runs them. Needs only the Swift toolchain.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
app="$here/../../MyApp"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -swift-version 5 -o "$out/checks" \
    "$app/Compass.swift" "$app/Aircraft.swift" "$app/Feed.swift" "$app/TestLocation.swift" "$app/Usage.swift" "$app/LocationFailure.swift" \
    "$app/BackendClient.swift" "$here/main.swift"
"$out/checks"
