#!/bin/bash

# Script to download CRC bundles to ~/.crc/cache
# Usage: ./download-bundle.sh <ocp_version>
# Example: ./download-bundle.sh 4.19

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
CRC_CACHE_DIR="${HOME}/.crc/cache"
BUNDLE_MIRROR_URL="https://mirror.openshift.com/pub/openshift-v4/clients/crc/bundles/openshift"

# Function to show usage
usage() {
    echo "Usage: $0 <ocp_version>"
    echo ""
    echo "Download CRC bundles to ~/.crc/cache"
    echo ""
    echo "Arguments:"
    echo "  ocp_version    OpenShift version (e.g., 4.18, 4.19, 4.20)"
    echo ""
    echo "Examples:"
    echo "  $0 4.19                    # Download bundle for OCP 4.19"
    echo "  $0 4.20                    # Download bundle for OCP 4.20"
    echo ""
    exit 1
}

# Check arguments
if [ $# -lt 1 ]; then
    usage
fi

OCP_VERSION="$1"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  CRC Bundle Downloader${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo "OCP Version: ${OCP_VERSION}"
echo "Cache Directory: ${CRC_CACHE_DIR}"
echo ""

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64)
        ARCH_NAME="amd64"
        BUNDLE_TYPE="libvirt"
        ;;
    aarch64|arm64)
        ARCH_NAME="arm64"
        BUNDLE_TYPE="vfkit"
        ;;
    *)
        echo -e "${RED}Unsupported architecture: $ARCH${NC}"
        exit 1
        ;;
esac

echo -e "${GREEN}Current architecture: ${ARCH_NAME} (${BUNDLE_TYPE})${NC}"
echo -e "${BLUE}Will download bundles for both amd64 and arm64${NC}"
echo ""

# Create cache directory if it doesn't exist
mkdir -p "$CRC_CACHE_DIR"

# Find latest patch version for this OCP version
echo -e "${YELLOW}Finding latest patch version for OCP ${OCP_VERSION}...${NC}"
AVAILABLE_VERSIONS=$(curl -s "${BUNDLE_MIRROR_URL}/" 2>/dev/null | \
    grep -oE "/${OCP_VERSION}\.[0-9]+/" | \
    grep -oE "${OCP_VERSION}\.[0-9]+" | \
    sort -V | tail -1)

if [ -z "$AVAILABLE_VERSIONS" ]; then
    echo -e "${RED}Error: Could not find any ${OCP_VERSION}.x versions on mirror${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Found OCP patch version: ${AVAILABLE_VERSIONS}${NC}"
echo ""

# Build bundle URL
BUNDLE_URL="${BUNDLE_MIRROR_URL}/${AVAILABLE_VERSIONS}/"
echo -e "${YELLOW}Searching for bundles at: ${BUNDLE_URL}${NC}"

# Find both bundle files
AMD64_BUNDLE=$(curl -s "$BUNDLE_URL" 2>/dev/null | \
    grep -oE "crc_libvirt_${OCP_VERSION}\.[0-9.]+_amd64\.crcbundle" | head -1)
ARM64_BUNDLE=$(curl -s "$BUNDLE_URL" 2>/dev/null | \
    grep -oE "crc_vfkit_${OCP_VERSION}\.[0-9.]+_arm64\.crcbundle" | head -1)

if [ -z "$AMD64_BUNDLE" ] && [ -z "$ARM64_BUNDLE" ]; then
    echo -e "${RED}Error: Could not find any bundles for OCP ${OCP_VERSION}${NC}"
    exit 1
fi

if [ -n "$AMD64_BUNDLE" ]; then
    echo -e "${GREEN}✓ Found amd64 bundle: ${AMD64_BUNDLE}${NC}"
fi
if [ -n "$ARM64_BUNDLE" ]; then
    echo -e "${GREEN}✓ Found arm64 bundle: ${ARM64_BUNDLE}${NC}"
fi
echo ""

# Function to download a bundle
download_bundle() {
    local bundle_file="$1"
    local arch_name="$2"
    local full_url="${BUNDLE_URL}${bundle_file}"
    local dest_file="${CRC_CACHE_DIR}/${bundle_file}"
    
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  Downloading ${arch_name} bundle${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    
    # Check if file already exists
    if [ -f "$dest_file" ]; then
        echo -e "${YELLOW}Bundle already exists: ${bundle_file}${NC}"
        FILE_SIZE=$(du -h "$dest_file" | cut -f1)
        echo -e "${GREEN}  Size: ${FILE_SIZE}${NC}"
        echo ""
        read -p "Re-download ${arch_name}? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo -e "${GREEN}✓ Skipping ${arch_name} bundle${NC}"
            echo ""
            return 0
        fi
        echo ""
    fi
    
    # Download bundle with progress
    echo -e "${YELLOW}Downloading ${arch_name} bundle (this may take 10-20 minutes for ~5-6 GB)...${NC}"
    echo -e "${BLUE}URL: ${full_url}${NC}"
    echo ""
    
    if curl -L --progress-bar --retry 3 --retry-delay 5 \
        -o "$dest_file" \
        "$full_url"; then
        echo ""
        echo -e "${GREEN}✓ ${arch_name} download complete!${NC}"
        FILE_SIZE=$(du -h "$dest_file" | cut -f1)
        echo -e "${GREEN}  Size: ${FILE_SIZE}${NC}"
        echo ""
        return 0
    else
        echo ""
        echo -e "${RED}✗ ${arch_name} download failed${NC}"
        echo ""
        # Clean up partial download
        rm -f "$dest_file"
        return 1
    fi
}

# Download both architectures
SUCCESS_COUNT=0
TOTAL_COUNT=0

if [ -n "$AMD64_BUNDLE" ]; then
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    if download_bundle "$AMD64_BUNDLE" "amd64"; then
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    fi
fi

if [ -n "$ARM64_BUNDLE" ]; then
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    if download_bundle "$ARM64_BUNDLE" "arm64"; then
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    fi
fi

# Final summary
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Download Summary${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Successfully downloaded: ${SUCCESS_COUNT}/${TOTAL_COUNT} bundles"
echo "Location: ${CRC_CACHE_DIR}"
echo ""

if [ $SUCCESS_COUNT -eq $TOTAL_COUNT ]; then
    echo -e "${GREEN}✓ All bundles are now available in your CRC cache.${NC}"
    echo -e "${GREEN}  You can use them with: crc setup${NC}"
    exit 0
elif [ $SUCCESS_COUNT -gt 0 ]; then
    echo -e "${YELLOW}⚠ Some bundles were downloaded, but not all succeeded.${NC}"
    exit 1
else
    echo -e "${RED}✗ No bundles were successfully downloaded.${NC}"
    exit 1
fi

