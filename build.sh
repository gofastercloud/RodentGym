#!/bin/zsh
# Builds RodentGym.app into ./build and installs it to ~/Applications.
#   ./build.sh               build and install
#   ./build.sh --no-install  build only
#   ./build.sh --screenshot  build, then regenerate the docs/ images (anonymised demo data)
set -euo pipefail
cd "${0:A:h}"

BUILD=build
APP="$BUILD/RodentGym.app"
rm -rf "$APP" "$BUILD/AppIcon.iconset"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD/AppIcon.iconset"

clang -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter -mmacosx-version-min=14.0 \
  -o "$APP/Contents/MacOS/RodentGym" Sources/*.m \
  -F/System/Library/PrivateFrameworks -framework MultitouchSupport \
  -framework Cocoa -framework IOKit -framework ApplicationServices -framework QuartzCore

# The app draws its own icon; render it and convert to .icns
"$APP/Contents/MacOS/RodentGym" --render-icon "$BUILD/icon_1024.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$BUILD/icon_1024.png" --out "$BUILD/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$BUILD/icon_1024.png" --out "$BUILD/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Help.html "$APP/Contents/Resources/Help.html"
codesign --force --options runtime --sign - "$APP"
echo "Built $APP"

case "${1:-}" in
  --no-install) ;;
  --screenshot)
    "$APP/Contents/MacOS/RodentGym" --snapshot "$PWD/docs/screenshot.png" --demo --appearance dark
    "$APP/Contents/MacOS/RodentGym" --snapshot-trainer "$PWD/docs/gesture-trainer.png" --appearance dark
    "$APP/Contents/MacOS/RodentGym" --snapshot-game "$PWD/docs/cheese-stack.png" --appearance light
    "$APP/Contents/MacOS/RodentGym" --snapshot-force "$PWD/docs/force-sensor.png" --appearance light
    echo "Wrote docs/*.png" ;;
  *)
    pkill -x RodentGym 2>/dev/null || true
    rm -rf "$HOME/Applications/RodentGym.app"
    mkdir -p "$HOME/Applications"
    cp -R "$APP" "$HOME/Applications/"
    echo "Installed ~/Applications/RodentGym.app" ;;
esac
