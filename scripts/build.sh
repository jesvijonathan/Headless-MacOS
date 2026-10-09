#!/bin/zsh
# Builds build/Headless.app (ad-hoc signed).
set -eu
cd "${0:A:h}/.."
app=build/Headless.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp Resources/Info.plist "$app/Contents/"
clang -O2 -Wall -Wextra -Wno-unused-parameter -fobjc-arc -mmacosx-version-min=14.0 \
    -framework Cocoa -framework Carbon -framework IOKit \
    Sources/Headless.m -o "$app/Contents/MacOS/Headless"
codesign --force --sign - "$app"
echo "Built $app"
