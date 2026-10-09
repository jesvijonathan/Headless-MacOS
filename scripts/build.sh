#!/bin/zsh
# Builds build/Headless.app (the agent) and build/headless-fand (root fan daemon), ad-hoc signed.
set -eu
cd "${0:A:h}/.."
if ! xcrun --find clang >/dev/null 2>&1 || ! xcrun --find swiftc >/dev/null 2>&1; then
    echo "Needs the Xcode Command Line Tools: run  xcode-select --install  and try again." >&2
    exit 1
fi
app=build/Headless.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp Resources/Info.plist "$app/Contents/"
clang -O2 -Wall -Wextra -Wno-unused-parameter -fobjc-arc -mmacosx-version-min=14.0 \
    -framework Cocoa -framework Carbon -framework IOKit \
    Sources/Headless.m -o "$app/Contents/MacOS/Headless"
swiftc -O -target arm64-apple-macos14 Sources/fand/SMC.swift Sources/fand/main.swift \
    -o build/headless-fand
codesign --force --sign - "$app"
codesign --force --sign - build/headless-fand
echo "Built $app and build/headless-fand"
