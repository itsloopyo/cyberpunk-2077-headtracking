#!/bin/bash
#
# package-release.sh - Package HeadTracking mod for release
#
# Creates a distributable ZIP file containing all mod files ready for
# installation into Cyberpunk 2077's CET mods directory.
#
# Usage:
#   ./package-release.sh [VERSION]
#
# Arguments:
#   VERSION - Optional version string (e.g., "1.0.0")
#             If not provided, uses git describe or "dev"
#
# Output:
#   dist/HeadTracking-v{VERSION}.zip
#
# Exit codes:
#   0 - Package created successfully
#   1 - Error during packaging
#

set -euo pipefail
IFS=$'\n\t'

# Color output (disabled if not a terminal)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    CYAN=''
    NC=''
fi

info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail()    { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Determine script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_ROOT"

echo ""
echo "========================================"
echo "  HeadTracking Release Packaging"
echo "========================================"
echo ""

# Determine version
VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    # Try git describe
    VERSION=$(git describe --tags --always 2>/dev/null || echo "dev")
    # Strip leading 'v' if present
    VERSION="${VERSION#v}"
fi

info "Version: $VERSION"
info "Project root: $PROJECT_ROOT"

# Required mod files
REQUIRED_MOD_FILES=(
    "init.lua"
    "modules/udp.lua"
    "modules/camera.lua"
    "modules/settings.lua"
    "modules/state.lua"
    "modules/ui.lua"
    "modules/GameUI.lua"
)

# Optional mod files to include if present
OPTIONAL_MOD_FILES=(
    "modules/nativesettings.lua"
)

# Documentation files to include
DOC_FILES=(
    "README.md"
)

echo ""
info "Validating required files..."

for file in "${REQUIRED_MOD_FILES[@]}"; do
    if [ ! -f "$file" ]; then
        fail "Missing required file: $file"
    fi
    echo -e "  ${GREEN}✓${NC} $file"
done

echo ""
info "Checking documentation files..."

for file in "${DOC_FILES[@]}"; do
    if [ ! -f "$file" ]; then
        warn "Missing documentation file: $file"
    else
        echo -e "  ${GREEN}✓${NC} $file"
    fi
done

# Create dist directory
DIST_DIR="$PROJECT_ROOT/dist"
mkdir -p "$DIST_DIR"

# Create staging directory
STAGING_DIR="$DIST_DIR/HeadTracking"
if [ -d "$STAGING_DIR" ]; then
    rm -rf "$STAGING_DIR"
fi
mkdir -p "$STAGING_DIR"
mkdir -p "$STAGING_DIR/modules"

info "Staging directory: $STAGING_DIR"

echo ""
info "Copying mod files..."

# Copy required mod files
cp "init.lua" "$STAGING_DIR/"
echo -e "  ${GREEN}✓${NC} init.lua"

for file in "${REQUIRED_MOD_FILES[@]}"; do
    if [[ "$file" == modules/* ]]; then
        cp "$file" "$STAGING_DIR/modules/"
        echo -e "  ${GREEN}✓${NC} $file"
    fi
done

# Copy optional mod files if they exist
for file in "${OPTIONAL_MOD_FILES[@]}"; do
    if [ -f "$file" ]; then
        cp "$file" "$STAGING_DIR/modules/"
        echo -e "  ${GREEN}✓${NC} $file (optional)"
    fi
done

echo ""
info "Copying documentation files..."

# Copy documentation files
for file in "${DOC_FILES[@]}"; do
    if [ -f "$file" ]; then
        cp "$file" "$STAGING_DIR/"
        echo -e "  ${GREEN}✓${NC} $file"
    fi
done

# Do NOT include config.json in the package
# Users should generate their own config via the mod's default creation

echo ""
info "Creating ZIP archive..."

# Create ZIP file
ZIP_NAME="HeadTracking-v${VERSION}.zip"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"

# Remove existing ZIP if present
if [ -f "$ZIP_PATH" ]; then
    rm -f "$ZIP_PATH"
fi

# Create ZIP from staging directory
cd "$DIST_DIR"
if command -v zip &> /dev/null; then
    zip -r "$ZIP_NAME" "HeadTracking"
elif command -v 7z &> /dev/null; then
    7z a -tzip "$ZIP_NAME" "HeadTracking"
else
    fail "No zip utility found. Install 'zip' or '7z' to create archives."
fi

# Clean up staging directory
rm -rf "$STAGING_DIR"

cd "$PROJECT_ROOT"

# Verify ZIP was created
if [ ! -f "$ZIP_PATH" ]; then
    fail "Failed to create ZIP archive"
fi

# Get file size
ZIP_SIZE=$(du -h "$ZIP_PATH" | cut -f1)

echo ""
echo "========================================"
success "Package created successfully!"
echo ""
echo "  File: $ZIP_PATH"
echo "  Size: $ZIP_SIZE"
echo ""
echo "Installation instructions:"
echo "  1. Extract ZIP to:"
echo "     Cyberpunk 2077/bin/x64/plugins/cyber_engine_tweaks/mods/"
echo "  2. The HeadTracking folder should be directly inside mods/"
echo ""

exit 0
