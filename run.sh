#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# Kill existing instance
pkill -f "Swift Hakchi2.app" 2>/dev/null || true
sleep 1

# Build
swift build

# Create .app bundle
APP="$PWD/.build/Swift Hakchi2.app/Contents"
mkdir -p "$APP/MacOS" "$APP/Resources"

# Copy binary + resources
cp .build/debug/SwiftHakchi "$APP/MacOS/SwiftHakchi"
cp -R .build/debug/SwiftHakchi_SwiftHakchi.bundle "$APP/Resources/" 2>/dev/null || true
cp SwiftHakchi/Resources/AppIcon.icns "$APP/Resources/AppIcon.icns"
cp Info.plist "$APP/Info.plist"

echo "Launching..."
open "$PWD/.build/Swift Hakchi2.app"
