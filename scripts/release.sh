#!/bin/bash
#
# release.sh - Create a versioned release of HeadTracking mod
#
# This script performs all pre-release validations, creates the release package,
# and creates a git tag for the release. It does NOT push to the remote -
# that must be done manually or by CI/CD.
#
# Usage:
#   ./release.sh <VERSION>
#
# Arguments:
#   VERSION - Required semantic version (e.g., "1.0.0")
#
# What this script does:
#   1. Validates working directory is clean
#   2. Validates semantic version format
#   3. Checks that version tag doesn't already exist
#   4. Validates changelog has an entry for the version
#   5. Runs pre-release validation
#   6. Creates the release package
#   7. Creates a git tag for the release
#
# Exit codes:
#   0 - Release created successfully
#   1 - Error during release process
#

set -euo pipefail
IFS=$'\n\t'

# Color output (disabled if not a terminal)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    CYAN=''
    BOLD=''
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
echo "  HeadTracking Release Script"
echo "========================================"
echo ""

# Check for version argument
VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "Usage: ./release.sh <major|minor|patch|X.Y.Z>"
    echo ""
    echo "Examples:"
    echo "  ./release.sh patch"
    echo "  ./release.sh minor"
    echo "  ./release.sh 1.0.0"
    echo "  ./release.sh 2.0.0-beta.1"
    echo ""
    fail "Release argument is required"
fi

info "Release argument: $VERSION"
info "Project root: $PROJECT_ROOT"

echo ""
info "Step 1/7: Resolving release version..."

# Accept either 'major|minor|patch' (bump from latest git tag) or a literal X.Y.Z[-prerelease].
ARG="$(echo "$VERSION" | tr '[:upper:]' '[:lower:]')"
if [[ "$ARG" == "major" || "$ARG" == "minor" || "$ARG" == "patch" ]]; then
    LATEST_TAG="$(git tag -l 'v*' --sort=-v:refname 2>/dev/null | head -n1)"
    if [ -n "$LATEST_TAG" ]; then
        CURRENT="${LATEST_TAG#v}"
    else
        CURRENT="0.0.0"
    fi
    CORE="${CURRENT%%-*}"
    CORE="${CORE%%+*}"
    if [[ ! "$CORE" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        fail "Cannot bump '$ARG': latest tag '$LATEST_TAG' is not in X.Y.Z form."
    fi
    MAJ="${BASH_REMATCH[1]}"; MIN="${BASH_REMATCH[2]}"; PAT="${BASH_REMATCH[3]}"
    case "$ARG" in
        major) VERSION="$((MAJ + 1)).0.0" ;;
        minor) VERSION="${MAJ}.$((MIN + 1)).0" ;;
        patch) VERSION="${MAJ}.${MIN}.$((PAT + 1))" ;;
    esac
    info "Bumped from $CURRENT ($LATEST_TAG) -> $VERSION"
elif [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]]; then
    echo "  Argument must be 'major', 'minor', 'patch', or a version like X.Y.Z or X.Y.Z-prerelease"
    echo "  Examples: major, minor, patch, 1.0.0, 2.1.0, 1.0.0-beta.1, 1.0.0-rc.1"
    fail "Invalid release argument: $VERSION"
fi
echo -e "  ${GREEN}✓${NC} Release version: $VERSION"

echo ""
info "Step 2/7: Checking git working directory..."

# Check for uncommitted changes
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    echo ""
    warn "Uncommitted changes detected:"
    git status --short
    echo ""
    fail "Working directory is not clean. Commit or stash changes first."
fi
echo -e "  ${GREEN}✓${NC} Working directory is clean"

echo ""
info "Step 3/7: Checking if tag already exists..."

# Check if tag already exists
TAG_NAME="v$VERSION"
if git tag -l "$TAG_NAME" | grep -q "$TAG_NAME"; then
    fail "Tag $TAG_NAME already exists. Choose a different version or delete the existing tag."
fi
echo -e "  ${GREEN}✓${NC} Tag $TAG_NAME does not exist"

echo ""
info "Step 4/7: Validating CHANGELOG.md..."

# Check that CHANGELOG.md exists
if [ ! -f "CHANGELOG.md" ]; then
    fail "CHANGELOG.md not found. Create a changelog file with an entry for version $VERSION."
fi

# Check for changelog entry
if ! grep -q "\[$VERSION\]" CHANGELOG.md; then
    fail "No changelog entry found for version $VERSION"
    echo ""
    echo "Add an entry to CHANGELOG.md:"
    echo "  ## [$VERSION] - $(date +%Y-%m-%d)"
    echo "  ### Added"
    echo "  - Your changes here"
fi
echo -e "  ${GREEN}✓${NC} Changelog entry found for version $VERSION"

echo ""
info "Step 5/7: Running pre-release validation..."

# Run validate-release script if available
if [ -f "$SCRIPT_DIR/validate-release.ps1" ]; then
    # Try PowerShell first (cross-platform pwsh)
    if command -v pwsh &> /dev/null; then
        if ! pwsh -NoProfile -ExecutionPolicy Bypass -File "$SCRIPT_DIR/validate-release.ps1" -Version "$VERSION"; then
            fail "Pre-release validation failed"
        fi
    elif command -v powershell &> /dev/null; then
        if ! powershell -NoProfile -ExecutionPolicy Bypass -File "$SCRIPT_DIR/validate-release.ps1" -Version "$VERSION"; then
            fail "Pre-release validation failed"
        fi
    else
        # Fall back to basic validation
        warn "PowerShell not available, running basic validation..."

        # Check required files
        REQUIRED_FILES=(
            "init.lua"
            "modules/udp.lua"
            "modules/camera.lua"
            "modules/settings.lua"
            "modules/state.lua"
            "modules/ui.lua"
            "modules/GameUI.lua"
            "README.md"
        )

        for file in "${REQUIRED_FILES[@]}"; do
            if [ ! -f "$file" ]; then
                fail "Missing required file: $file"
            fi
        done
        echo -e "  ${GREEN}✓${NC} All required files present"
    fi
else
    warn "validate-release.ps1 not found, skipping pre-release validation"
fi

echo ""
info "Step 6/7: Creating release package..."

# Run package script
PACKAGE_SCRIPT="$SCRIPT_DIR/package-release.sh"
if [ -f "$PACKAGE_SCRIPT" ]; then
    if ! bash "$PACKAGE_SCRIPT" "$VERSION"; then
        fail "Package creation failed"
    fi
else
    fail "Package script not found: $PACKAGE_SCRIPT"
fi

# Verify package was created
PACKAGE_PATH="$PROJECT_ROOT/dist/HeadTracking-v$VERSION.zip"
if [ ! -f "$PACKAGE_PATH" ]; then
    fail "Package not created at expected location: $PACKAGE_PATH"
fi
echo -e "  ${GREEN}✓${NC} Package created: $PACKAGE_PATH"

echo ""
info "Step 7/7: Creating git tag..."

# Create annotated git tag
git tag -a "$TAG_NAME" -m "Release $TAG_NAME

HeadTracking mod version $VERSION for Cyberpunk 2077.

See CHANGELOG.md for release notes."

echo -e "  ${GREEN}✓${NC} Created git tag: $TAG_NAME"

echo ""
echo "========================================"
success "Release v$VERSION prepared successfully!"
echo ""
echo -e "${BOLD}Summary:${NC}"
echo "  • Package: dist/HeadTracking-v$VERSION.zip"
echo "  • Git tag: $TAG_NAME (local)"
echo ""
echo -e "${BOLD}Next steps:${NC}"
echo ""
echo "  To publish the release to GitHub:"
echo -e "    ${CYAN}git push origin $TAG_NAME${NC}"
echo ""
echo "  GitHub Actions will automatically:"
echo "  • Create a GitHub Release"
echo "  • Upload the package as a release asset"
echo ""
echo "  To upload to Nexus Mods:"
echo "  • Go to https://www.nexusmods.com/cyberpunk2077/mods/<your-mod-id>"
echo "  • Upload dist/HeadTracking-v$VERSION.zip"
echo ""
echo "  To undo this release (if needed):"
echo -e "    ${CYAN}git tag -d $TAG_NAME${NC}"
echo ""

exit 0
