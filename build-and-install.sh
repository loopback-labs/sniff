#!/bin/bash

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_PATH="$SCRIPT_DIR/sniff.xcodeproj"
DERIVED_DATA_PATH="$SCRIPT_DIR/Build/DerivedData"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/Sniff.app"

if [ ! -d "$PROJECT_PATH" ]; then
    echo "Error: sniff.xcodeproj not found in $SCRIPT_DIR"
    exit 1
fi

xcodebuild -project "$PROJECT_PATH" \
    -scheme sniff \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    clean build

if [ ! -d "$APP_PATH" ]; then
    echo "Error: build succeeded but app not found at $APP_PATH"
    exit 1
fi

for old_app in "/Applications/Sniff.app"; do
    [ -d "$old_app" ] && rm -rf "$old_app"
done

cp -R "$APP_PATH" /Applications/

echo "Installed to /Applications/Sniff.app"
