#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Building Sniff app...${NC}"

# Get the directory where the script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_PATH="$SCRIPT_DIR/sniff.xcodeproj"
DERIVED_DATA_PATH="$SCRIPT_DIR/Build/DerivedData"

# Check if Xcode project exists
if [ ! -d "$PROJECT_PATH" ]; then
    echo -e "${RED}Error: sniff.xcodeproj not found in $SCRIPT_DIR${NC}"
    exit 1
fi

# Clean and build the project
echo -e "${YELLOW}Cleaning and building project...${NC}"
xcodebuild -project "$PROJECT_PATH" \
    -scheme sniff \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    clean build

if [ $? -ne 0 ]; then
    echo -e "${RED}Build failed!${NC}"
    exit 1
fi

echo -e "${GREEN}Build succeeded!${NC}"

# Find the built app from the derived data path we just used
APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/sniff.app"

if [ ! -d "$APP_PATH" ]; then
    echo -e "${RED}Error: Could not find built app${NC}"
    exit 1
fi

echo -e "${YELLOW}Found app at: $APP_PATH${NC}"

# Install to Applications folder
echo -e "${YELLOW}Installing to /Applications...${NC}"

# Remove old version if it exists
if [ -d "/Applications/sniff.app" ]; then
    echo -e "${YELLOW}Removing old version...${NC}"
    rm -rf /Applications/sniff.app
fi

# Copy new version
cp -R "$APP_PATH" /Applications/

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Sniff.app successfully installed to /Applications/${NC}"
    echo ""
    echo "You can now launch the app from:"
    echo "  • Applications folder"
    echo "  • Spotlight (⌘Space, type 'sniff')"
    echo "  • Command: open /Applications/sniff.app"
    echo ""
    echo -e "${YELLOW}Note: Remember to grant required permissions on first launch:${NC}"
    echo "  • Screen Recording"
    echo "  • Microphone"
    echo "  • Speech Recognition"
    echo "  • Accessibility (for keyboard shortcuts)"
else
    echo -e "${RED}Installation failed!${NC}"
    exit 1
fi
