#!/bin/zsh
# Builds CoffeeCup.app with the Command Line Tools (no Xcode project needed).
# Usage: ./build.sh            -> build/CoffeeCup.app (universal: arm64 + x86_64)
#        ./build.sh install    -> also copies to /Applications and launches it
#        ./build.sh dist       -> also creates build/CoffeeCup.zip for a release
set -euo pipefail

cd "${0:a:h}"
APP="build/CoffeeCup.app"
BIN="$APP/Contents/MacOS/CoffeeCup"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  swiftc -O \
    -target "$arch-apple-macos13.0" \
    -framework AppKit -framework IOKit -framework ServiceManagement \
    -o "build/CoffeeCup-$arch" \
    Sources/main.swift
done
lipo -create -output "$BIN" build/CoffeeCup-arm64 build/CoffeeCup-x86_64
rm build/CoffeeCup-arm64 build/CoffeeCup-x86_64

cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature so Gatekeeper/SMAppService accept the locally built app.
codesign --force --sign - "$APP"
echo "Built $APP ($(lipo -archs "$BIN"))"

case "${1:-}" in
  install)
    pkill -x CoffeeCup 2>/dev/null || true
    rm -rf /Applications/CoffeeCup.app
    cp -R "$APP" /Applications/
    open /Applications/CoffeeCup.app
    echo "Installed to /Applications and launched"
    ;;
  dist)
    ditto -c -k --keepParent "$APP" build/CoffeeCup.zip
    echo "Created build/CoffeeCup.zip"
    ;;
esac
