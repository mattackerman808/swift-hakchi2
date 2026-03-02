#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# Kill existing instance
pkill -f "Swift Hakchi.app" 2>/dev/null || true
sleep 1

# Build
swift build

# Create .app bundle
APP="$PWD/.build/Swift Hakchi.app/Contents"
mkdir -p "$APP/MacOS" "$APP/Resources"

# Copy binary + resources
cp .build/debug/SwiftHakchi "$APP/MacOS/SwiftHakchi"
cp -R .build/debug/SwiftHakchi_SwiftHakchi.bundle "$APP/Resources/" 2>/dev/null || true
cp Info.plist "$APP/Info.plist"

echo "Launching..."
open "$PWD/.build/Swift Hakchi.app"
