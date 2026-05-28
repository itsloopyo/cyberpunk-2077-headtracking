#!/bin/bash
#
# validate.sh - Validate HeadTracking mod structure for CI/CD
#
# This script checks that all required mod files are present and have valid
# Lua syntax. Used by GitHub Actions for build validation.
#
# Exit codes:
#   0 - All validations passed
#   1 - Validation failed (missing files or syntax errors)
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
fail()    { echo -e "${RED}[ERROR]${NC} $1"; }

# Determine script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_ROOT"

info "Validating HeadTracking mod structure..."
info "Project root: $PROJECT_ROOT"

ERRORS=0

# Required files for the mod to function
REQUIRED_FILES=(
    "init.lua"
    "modules/udp.lua"
    "modules/camera.lua"
    "modules/settings.lua"
    "modules/state.lua"
    "modules/ui.lua"
    "modules/GameUI.lua"
)

# Optional files that should be present for release
OPTIONAL_FILES=(
    "modules/nativesettings.lua"
    "config.json"
)

echo ""
info "Checking required files..."

for file in "${REQUIRED_FILES[@]}"; do
    if [ -f "$file" ]; then
        echo -e "  ${GREEN}✓${NC} $file"
    else
        echo -e "  ${RED}✗${NC} $file (MISSING)"
        ERRORS=$((ERRORS + 1))
    fi
done

echo ""
info "Checking optional files..."

for file in "${OPTIONAL_FILES[@]}"; do
    if [ -f "$file" ]; then
        echo -e "  ${GREEN}✓${NC} $file"
    else
        echo -e "  ${YELLOW}○${NC} $file (not present)"
    fi
done

echo ""
info "Checking modules directory structure..."

if [ -d "modules" ]; then
    MODULE_COUNT=$(find modules -name "*.lua" -type f | wc -l)
    echo -e "  ${GREEN}✓${NC} modules/ directory exists ($MODULE_COUNT Lua files)"
else
    echo -e "  ${RED}✗${NC} modules/ directory missing"
    ERRORS=$((ERRORS + 1))
fi

echo ""
info "Checking Lua syntax..."

# Check if luac is available for syntax checking
SYNTAX_CHECKER=""
if command -v luac &> /dev/null; then
    SYNTAX_CHECKER="luac"
elif command -v lua &> /dev/null; then
    SYNTAX_CHECKER="lua"
fi

if [ -n "$SYNTAX_CHECKER" ]; then
    SYNTAX_ERRORS=0

    for file in init.lua modules/*.lua; do
        if [ -f "$file" ]; then
            if [ "$SYNTAX_CHECKER" = "luac" ]; then
                if luac -p "$file" 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} $file"
                else
                    echo -e "  ${RED}✗${NC} $file (syntax error)"
                    SYNTAX_ERRORS=$((SYNTAX_ERRORS + 1))
                fi
            else
                # Use lua -e to check syntax
                if lua -e "loadfile('$file')" 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} $file"
                else
                    echo -e "  ${RED}✗${NC} $file (syntax error)"
                    SYNTAX_ERRORS=$((SYNTAX_ERRORS + 1))
                fi
            fi
        fi
    done

    if [ $SYNTAX_ERRORS -gt 0 ]; then
        ERRORS=$((ERRORS + SYNTAX_ERRORS))
        fail "Found $SYNTAX_ERRORS syntax error(s)"
    else
        success "All Lua files have valid syntax"
    fi
else
    warn "No Lua interpreter found, skipping syntax check"
    warn "Install lua or luac for syntax validation"
fi

echo ""
info "Checking module export patterns..."

# Check that each module returns something (basic pattern check)
MODULE_EXPORT_ERRORS=0

for file in modules/*.lua; do
    if [ -f "$file" ]; then
        # Check if file ends with a return statement
        if grep -q "^return " "$file"; then
            echo -e "  ${GREEN}✓${NC} $file exports module"
        else
            # Check for return at the end of file
            LAST_RETURN=$(grep -n "^return" "$file" | tail -1 || true)
            if [ -n "$LAST_RETURN" ]; then
                echo -e "  ${GREEN}✓${NC} $file exports module"
            else
                echo -e "  ${YELLOW}!${NC} $file may not export properly (no 'return' found)"
            fi
        fi
    fi
done

echo ""
info "Checking init.lua structure..."

INIT_CHECKS=0

# Check for required CET event registrations
if grep -q "registerForEvent.*onInit" init.lua; then
    echo -e "  ${GREEN}✓${NC} registerForEvent('onInit') present"
else
    echo -e "  ${RED}✗${NC} registerForEvent('onInit') missing"
    INIT_CHECKS=$((INIT_CHECKS + 1))
fi

if grep -q "registerForEvent.*onUpdate" init.lua; then
    echo -e "  ${GREEN}✓${NC} registerForEvent('onUpdate') present"
else
    echo -e "  ${RED}✗${NC} registerForEvent('onUpdate') missing"
    INIT_CHECKS=$((INIT_CHECKS + 1))
fi

if grep -q "registerForEvent.*onDraw" init.lua; then
    echo -e "  ${GREEN}✓${NC} registerForEvent('onDraw') present"
else
    echo -e "  ${YELLOW}○${NC} registerForEvent('onDraw') not found (optional)"
fi

if grep -q "registerForEvent.*onShutdown" init.lua; then
    echo -e "  ${GREEN}✓${NC} registerForEvent('onShutdown') present"
else
    echo -e "  ${YELLOW}○${NC} registerForEvent('onShutdown') not found (optional)"
fi

if grep -q "registerHotkey" init.lua; then
    HOTKEY_COUNT=$(grep -c "registerHotkey" init.lua || true)
    echo -e "  ${GREEN}✓${NC} registerHotkey calls found ($HOTKEY_COUNT)"
else
    echo -e "  ${RED}✗${NC} No registerHotkey calls found"
    INIT_CHECKS=$((INIT_CHECKS + 1))
fi

if [ $INIT_CHECKS -gt 0 ]; then
    ERRORS=$((ERRORS + INIT_CHECKS))
fi

echo ""
info "Checking for common issues..."

# Check for debug/development leftovers
if grep -rn "print.*DEBUG\|print.*TODO\|--.*TODO\|--.*FIXME\|--.*HACK" init.lua modules/*.lua 2>/dev/null; then
    warn "Found debug/TODO comments (consider removing before release)"
fi

# Check for hardcoded paths
if grep -rn "C:\\\|D:\\\|/home/" init.lua modules/*.lua 2>/dev/null; then
    warn "Found hardcoded paths (may cause issues on other systems)"
fi

echo ""
echo "========================================"

if [ $ERRORS -eq 0 ]; then
    success "All validations passed!"
    echo ""
    exit 0
else
    fail "Validation failed with $ERRORS error(s)"
    echo ""
    exit 1
fi
