#!/bin/bash
# Builds "Polling Rate Tester.app" with just the Xcode command line tools (no Xcode project needed).
# Usage:  chmod +x build.sh && ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

APP="Polling Rate Tester.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -parse-as-library -swift-version 5 \
  -target "$(uname -m)-apple-macos13.0" \
  PollingRateTester.swift \
  -o "$APP/Contents/MacOS/PollingRateTester" \
  -framework IOKit -framework AppKit -framework SwiftUI

cp Info.plist "$APP/Contents/Info.plist"

# Optional app icon: put AppIcon.icns next to this script (see make_icon.sh)
if [ -f AppIcon.icns ]; then
  mkdir -p "$APP/Contents/Resources"
  cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Optional macOS 26 icon: put AppIcon.icon (from Icon Composer) next to this script.
# Needs the full Xcode 26 app, because actool is not part of the command line tools.
XCODE_DIR="/Applications/Xcode.app/Contents/Developer"
if [ -d AppIcon.icon ]; then
  mkdir -p "$APP/Contents/Resources"
  if [ -d "$XCODE_DIR" ] && DEVELOPER_DIR="$XCODE_DIR" xcrun actool AppIcon.icon \
      --compile "$APP/Contents/Resources" \
      --output-format human-readable-text --notices --warnings --errors \
      --output-partial-info-plist /dev/null \
      --app-icon AppIcon --include-all-app-icons \
      --enable-on-demand-resources NO; then
    echo "Compiled AppIcon.icon into Assets.car"
  else
    echo "warning: could not compile AppIcon.icon (is Xcode 26 installed in /Applications?) — continuing without it"
  fi
fi

# Ad-hoc sign (required on Apple Silicon, and lets macOS track the privacy permission)
codesign --force --sign - "$APP"

echo "Built: $PWD/$APP"
open "$APP"
