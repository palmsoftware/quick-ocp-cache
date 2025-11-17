#!/bin/bash
set -e

# Test script for CRC mirror availability
# Usage: ./test-mirror.sh [OCP_VERSION]
#
# Examples:
#   ./test-mirror.sh          # Test all configured versions
#   ./test-mirror.sh 4.19     # Test specific version

OCP_VERSION="${1}"
CRC_MIRROR_URL="https://developers.redhat.com/content-gateway/rest/mirror/pub/openshift-v4/clients/crc"
BUNDLE_MIRROR_NEW="https://mirror.openshift.com/pub/openshift-v4/clients/crc/bundles/openshift"
BUNDLE_MIRROR_OLD="https://developers.redhat.com/content-gateway/rest/mirror/pub/openshift-v4/clients/crc"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Track test results
PASSED=0
FAILED=0
WARNINGS=0

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  CRC Mirror Availability Test Suite${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Test function
test_case() {
    local test_name="$1"
    echo -e "${YELLOW}[TEST]${NC} $test_name"
}

test_pass() {
    echo -e "${GREEN}  ✓ PASS${NC}"
    ((PASSED++))
    echo ""
}

test_fail() {
    local reason="$1"
    echo -e "${RED}  ✗ FAIL${NC}: $reason"
    ((FAILED++))
    echo ""
}

test_warn() {
    local reason="$1"
    echo -e "${YELLOW}  ⚠ WARN${NC}: $reason"
    ((WARNINGS++))
    echo ""
}

# Function to get CRC version for OCP version
get_crc_version() {
    local ocp_ver="$1"
    case "$ocp_ver" in
        "4.18") echo "2.51.0" ;;
        "4.19") echo "2.54.0" ;;
        "4.20") echo "2.56.0" ;;
        *) echo "unknown" ;;
    esac
}

# Function to check URL availability
check_url() {
    local url="$1"
    local follow_redirects="${2:-true}"
    
    if [ "$follow_redirects" = "true" ]; then
        curl -s -L -I -f --max-time 10 "$url" > /dev/null 2>&1
    else
        curl -s -I -f --max-time 10 "$url" > /dev/null 2>&1
    fi
    return $?
}

# Function to get content size from URL
get_content_size() {
    local url="$1"
    # Get the LAST Content-Length header (after all redirects)
    curl -s -L -I "$url" 2>/dev/null | grep -i "content-length" | awk '{print $2}' | tr -d '\r' | tail -1
}

# Function to find bundle file
find_bundle_file() {
    local url="$1"
    local pattern="$2"
    # Use grep -E (extended regex) instead of -P (Perl regex) for macOS compatibility
    curl -s "$url" 2>/dev/null | grep -oE "$pattern" | head -1
}

# Test a specific OCP version
test_ocp_version() {
    local ocp_ver="$1"
    local crc_ver=$(get_crc_version "$ocp_ver")
    
    if [ "$crc_ver" = "unknown" ]; then
        echo -e "${YELLOW}Skipping OCP $ocp_ver - no CRC version mapping${NC}"
        echo ""
        return
    fi
    
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Testing OCP ${ocp_ver} (CRC ${crc_ver})${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    
    # Test 1: CRC version directory exists
    test_case "CRC version directory accessible"
    VERSION_URL="${CRC_MIRROR_URL}/${crc_ver}/"
    if check_url "$VERSION_URL"; then
        echo -e "  URL: ${GREEN}${VERSION_URL}${NC}"
        test_pass
    else
        echo -e "  URL: ${RED}${VERSION_URL}${NC}"
        test_fail "Version directory not accessible"
    fi
    
    # Test 2: AMD64 binary exists
    test_case "CRC binary (amd64) exists and is accessible"
    BINARY_AMD64_URL="${CRC_MIRROR_URL}/${crc_ver}/crc-linux-amd64.tar.xz"
    if check_url "$BINARY_AMD64_URL"; then
        SIZE=$(get_content_size "$BINARY_AMD64_URL")
        if [ -n "$SIZE" ] && [ "$SIZE" -gt 10485760 ]; then  # > 10 MB
            # Format size in human readable format
            SIZE_MB=$((SIZE / 1048576))
            echo -e "  URL: ${GREEN}${BINARY_AMD64_URL}${NC}"
            echo -e "  Size: ${GREEN}${SIZE_MB} MB${NC}"
            test_pass
        else
            echo -e "  URL: ${YELLOW}${BINARY_AMD64_URL}${NC}"
            echo -e "  Size: ${YELLOW}${SIZE} bytes${NC}"
            test_warn "Binary size seems too small: ${SIZE} bytes"
        fi
    else
        echo -e "  URL: ${RED}${BINARY_AMD64_URL}${NC}"
        test_fail "Binary not accessible"
    fi
    
    # Test 3: ARM64 binary exists
    test_case "CRC binary (arm64) exists and is accessible"
    BINARY_ARM64_URL="${CRC_MIRROR_URL}/${crc_ver}/crc-linux-arm64.tar.xz"
    if check_url "$BINARY_ARM64_URL"; then
        SIZE=$(get_content_size "$BINARY_ARM64_URL")
        if [ -n "$SIZE" ] && [ "$SIZE" -gt 10485760 ]; then  # > 10 MB
            # Format size in human readable format
            SIZE_MB=$((SIZE / 1048576))
            echo -e "  URL: ${GREEN}${BINARY_ARM64_URL}${NC}"
            echo -e "  Size: ${GREEN}${SIZE_MB} MB${NC}"
            test_pass
        else
            echo -e "  URL: ${YELLOW}${BINARY_ARM64_URL}${NC}"
            echo -e "  Size: ${YELLOW}${SIZE} bytes${NC}"
            test_warn "Binary size seems too small: ${SIZE} bytes"
        fi
    else
        echo -e "  URL: ${RED}${BINARY_ARM64_URL}${NC}"
        test_fail "Binary not accessible"
    fi
    
    # Test 4: Bundle availability (find latest patch version for this OCP version)
    test_case "Bundle availability (${BUNDLE_MIRROR_NEW}/)"
    # First, get the list of available OCP versions and find the latest patch for our major.minor version
    AVAILABLE_VERSIONS=$(curl -s "${BUNDLE_MIRROR_NEW}/" | grep -oE "/${ocp_ver}\.[0-9]+/" | grep -oE "${ocp_ver}\.[0-9]+" | sort -V | tail -1)
    
    if [ -n "$AVAILABLE_VERSIONS" ]; then
        NEW_BUNDLE_URL="${BUNDLE_MIRROR_NEW}/${AVAILABLE_VERSIONS}/"
        echo -e "  Found OCP version: ${GREEN}${AVAILABLE_VERSIONS}${NC}"
        
        if check_url "$NEW_BUNDLE_URL"; then
            # Look for bundle files in this version directory (prefer libvirt for Linux compatibility)
            BUNDLE_FILE=$(curl -s "$NEW_BUNDLE_URL" | grep -oE 'crc_libvirt_[0-9.]+_amd64\.crcbundle' | head -1)
            if [ -n "$BUNDLE_FILE" ]; then
                FULL_BUNDLE_URL="${NEW_BUNDLE_URL}${BUNDLE_FILE}"
                echo -e "  Found: ${GREEN}${BUNDLE_FILE}${NC}"
                
                # Check if bundle is accessible
                if check_url "$FULL_BUNDLE_URL"; then
                    SIZE=$(get_content_size "$FULL_BUNDLE_URL")
                    if [ -n "$SIZE" ] && [ "$SIZE" -gt 1073741824 ]; then  # > 1 GB
                        # Format size in human readable format
                        SIZE_GB=$((SIZE / 1073741824))
                        echo -e "  Size: ${GREEN}${SIZE_GB} GB${NC}"
                        test_pass
                    else
                        echo -e "  Size: ${YELLOW}${SIZE} bytes${NC}"
                        test_warn "Bundle size seems too small: ${SIZE} bytes"
                    fi
                else
                    test_warn "Bundle file found but not accessible"
                fi
            else
                echo -e "  URL: ${YELLOW}${NEW_BUNDLE_URL}${NC}"
                test_fail "No bundle file found in directory"
            fi
        else
            echo -e "  URL: ${YELLOW}${NEW_BUNDLE_URL}${NC}"
            test_fail "Bundle directory not accessible"
        fi
    else
        echo -e "  URL: ${YELLOW}${BUNDLE_MIRROR_NEW}${NC}"
        test_fail "No ${ocp_ver}.x bundle versions found in new location"
    fi
    
    echo ""
}

# Main execution
if [ -n "$OCP_VERSION" ]; then
    # Test specific version
    test_ocp_version "$OCP_VERSION"
else
    # Test all versions from ocp-versions.json if it exists
    if [ -f ocp-versions.json ]; then
        echo -e "${YELLOW}Loading versions from ocp-versions.json...${NC}"
        VERSIONS=$(jq -r '.versions[]' ocp-versions.json)
        echo ""
    else
        echo -e "${YELLOW}No ocp-versions.json found, testing default versions...${NC}"
        VERSIONS="4.18 4.19 4.20"
        echo ""
    fi
    
    for ver in $VERSIONS; do
        test_ocp_version "$ver"
    done
fi

# Summary
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Test Summary${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo -e "${GREEN}Passed:${NC}   $PASSED"
echo -e "${YELLOW}Warnings:${NC} $WARNINGS"
echo -e "${RED}Failed:${NC}   $FAILED"
echo ""

if [ $FAILED -eq 0 ]; then
    if [ $WARNINGS -eq 0 ]; then
        echo -e "${GREEN}✓ All tests passed!${NC}"
        echo -e "${GREEN}✓ All mirrors are accessible and files are available.${NC}"
        exit 0
    else
        echo -e "${YELLOW}⚠ Tests passed with warnings${NC}"
        echo -e "${YELLOW}⚠ Some issues detected but builds may still work.${NC}"
        exit 0
    fi
else
    echo -e "${RED}✗ Some tests failed${NC}"
    echo -e "${RED}✗ Mirror issues detected. Cache builds may fail.${NC}"
    exit 1
fi

