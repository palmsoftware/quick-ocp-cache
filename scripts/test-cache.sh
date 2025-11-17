#!/bin/bash
set -e

# Test script for CRC cache images
# Usage: ./test-cache.sh [OCP_VERSION] [ARCHITECTURE]
#
# Examples:
#   ./test-cache.sh          # Test default version (4.19) on amd64
#   ./test-cache.sh 4.20     # Test specific version
#   ./test-cache.sh 4.19 arm64  # Test specific version and architecture

OCP_VERSION="${1:-4.19}"
ARCHITECTURE="${2:-amd64}"
REGISTRY="quay.io"
IMAGE_NAME="bapalm/quick-ocp-cache"
IMAGE_TAG="${REGISTRY}/${IMAGE_NAME}:${OCP_VERSION}"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  CRC Cache Image Test Suite${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo -e "${YELLOW}Image:${NC} $IMAGE_TAG"
echo -e "${YELLOW}Architecture:${NC} $ARCHITECTURE"
echo ""

# Track test results
PASSED=0
FAILED=0

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

# Test 1: Image exists and can be pulled
test_case "Pull image from registry"
if docker pull --platform "linux/${ARCHITECTURE}" "$IMAGE_TAG" > /dev/null 2>&1; then
    test_pass
else
    test_fail "Failed to pull image"
fi

# Test 2: Image can be run
test_case "Run image and display default output"
if docker run --rm --platform "linux/${ARCHITECTURE}" "$IMAGE_TAG" > /dev/null 2>&1; then
    test_pass
else
    test_fail "Failed to run image"
fi

# Test 3: Metadata file exists and is valid JSON
test_case "Verify metadata.json exists and is valid"
METADATA=$(docker run --rm --platform "linux/${ARCHITECTURE}" "$IMAGE_TAG" cat /cache/metadata.json 2>/dev/null)
if echo "$METADATA" | jq . > /dev/null 2>&1; then
    echo "$METADATA" | jq .
    test_pass
else
    test_fail "metadata.json missing or invalid"
fi

# Test 4: Check OCP version in metadata
test_case "Verify OCP version in metadata"
METADATA_OCP=$(echo "$METADATA" | jq -r '.ocp_version')
if [ "$METADATA_OCP" == "$OCP_VERSION" ]; then
    echo -e "  OCP Version: ${GREEN}$METADATA_OCP${NC}"
    test_pass
else
    test_fail "OCP version mismatch: expected $OCP_VERSION, got $METADATA_OCP"
fi

# Test 5: Verify CRC version exists
test_case "Verify CRC version in image"
CRC_VERSION=$(docker run --rm --platform "linux/${ARCHITECTURE}" "$IMAGE_TAG" cat /cache/crc_version.txt 2>/dev/null)
if [ -n "$CRC_VERSION" ] && [ "$CRC_VERSION" != "" ]; then
    echo -e "  CRC Version: ${GREEN}$CRC_VERSION${NC}"
    test_pass
else
    test_fail "CRC version file missing or empty"
fi

# Test 6: Verify binary exists and has reasonable size
test_case "Verify CRC binary exists and has reasonable size"
BINARY_SIZE=$(docker run --rm --platform "linux/${ARCHITECTURE}" "$IMAGE_TAG" stat -c%s /cache/crc-binary.tar.xz 2>/dev/null || docker run --rm --platform "linux/${ARCHITECTURE}" "$IMAGE_TAG" stat -f%z /cache/crc-binary.tar.xz 2>/dev/null)
if [ -n "$BINARY_SIZE" ] && [ "$BINARY_SIZE" -gt 10485760 ]; then  # > 10 MB
    echo -e "  Binary Size: ${GREEN}$(numfmt --to=iec-i --suffix=B $BINARY_SIZE)${NC}"
    test_pass
else
    test_fail "Binary missing or too small: $BINARY_SIZE bytes"
fi

# Test 7: Verify bundle exists and has reasonable size
test_case "Verify CRC bundle exists and has reasonable size"
BUNDLE_SIZE=$(docker run --rm --platform "linux/${ARCHITECTURE}" "$IMAGE_TAG" stat -c%s /cache/bundle.crcbundle 2>/dev/null || docker run --rm --platform "linux/${ARCHITECTURE}" "$IMAGE_TAG" stat -f%z /cache/bundle.crcbundle 2>/dev/null)
if [ -n "$BUNDLE_SIZE" ] && [ "$BUNDLE_SIZE" -gt 1073741824 ]; then  # > 1 GB
    echo -e "  Bundle Size: ${GREEN}$(numfmt --to=iec-i --suffix=B $BUNDLE_SIZE)${NC}"
    test_pass
else
    test_fail "Bundle missing or too small: $BUNDLE_SIZE bytes"
fi

# Test 8: Verify extraction script exists and is executable
test_case "Verify extraction script exists and is executable"
if docker run --rm --platform "linux/${ARCHITECTURE}" "$IMAGE_TAG" test -x /cache/extract.sh; then
    test_pass
else
    test_fail "extract.sh missing or not executable"
fi

# Test 9: Test extraction to temporary directory
test_case "Test extraction to temporary directory"
TEMP_DIR=$(mktemp -d)
CONTAINER_ID=$(docker create --platform "linux/${ARCHITECTURE}" "$IMAGE_TAG")

cleanup_container() {
    docker rm "$CONTAINER_ID" > /dev/null 2>&1 || true
    rm -rf "$TEMP_DIR"
}
trap cleanup_container EXIT

if docker cp "$CONTAINER_ID:/cache/crc-binary.tar.xz" "$TEMP_DIR/crc.tar.xz" && \
   [ -f "$TEMP_DIR/crc.tar.xz" ] && \
   [ $(stat -c%s "$TEMP_DIR/crc.tar.xz" 2>/dev/null || stat -f%z "$TEMP_DIR/crc.tar.xz") -gt 10485760 ]; then
    echo -e "  Extracted to: ${GREEN}$TEMP_DIR${NC}"
    test_pass
else
    test_fail "Failed to extract binary"
fi

# Test 10: Verify image labels
test_case "Verify image labels"
LABELS=$(docker inspect --format='{{json .Config.Labels}}' "$IMAGE_TAG" 2>/dev/null)
if echo "$LABELS" | jq -e '.name' > /dev/null 2>&1; then
    echo "$LABELS" | jq .
    test_pass
else
    test_fail "Image labels missing or invalid"
fi

# Summary
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Test Summary${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo -e "${GREEN}Passed:${NC} $PASSED"
echo -e "${RED}Failed:${NC} $FAILED"
echo ""

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}✓ All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}✗ Some tests failed${NC}"
    exit 1
fi

