#!/bin/bash
# Build Core Monitor and install it to /Applications.
set -e
cd "$(dirname "$0")"
APP="/Applications/Core Monitor.app"
swiftc -O -parse-as-library main.swift processes.swift temps.swift netnames.swift -o /tmp/cm_build
pkill -x CoreMonitor || true; sleep 1
mkdir -p "$APP/Contents/MacOS"
mv /tmp/cm_build "$APP/Contents/MacOS/CoreMonitor"
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"; cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; touch "$APP"
codesign --force -s - "$APP"
open "$APP"
