#!/bin/bash
set -e

# This script downloads CRC binary and bundle from cached container image
# Usage: ./download-from-cache.sh <OCP_VERSION> [REGISTRY] [ARCHITECTURE]
#
# Examples:
#   ./download-from-cache.sh 4.19
#   ./download-from-cache.sh 4.19 quay.io
#   ./download-from-cache.sh 4.19 quay.io arm64

OCP_VERSION="$1"
REGISTRY="${2:-quay.io}"
ARCHITECTURE="${3:-amd64}"
IMAGE_NAME="bapalm/quick-ocp-cache"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

if [ -z "$OCP_VERSION" ]; then
  echo -e "${RED}Error: OCP version required${NC}"
  echo "Usage: $0 <OCP_VERSION> [REGISTRY] [ARCHITECTURE]"
  echo ""
  echo "Examples:"
  echo "  $0 4.19"
  echo "  $0 4.19 quay.io"
  echo "  $0 4.19 quay.io arm64"
  exit 1
fi

IMAGE_TAG="${REGISTRY}/${IMAGE_NAME}:${OCP_VERSION}"

echo -e "${GREEN}=== Downloading CRC from cache image ===${NC}"
echo "Image: $IMAGE_TAG"
echo "OCP Version: $OCP_VERSION"
echo "Architecture: $ARCHITECTURE"
echo ""

# Check if Docker is available
if ! command -v docker &> /dev/null; then
    echo -e "${RED}Error: Docker is not installed or not in PATH${NC}"
    exit 1
fi

# Pull the image
echo -e "${YELLOW}Pulling image...${NC}"
if ! docker pull --platform "linux/${ARCHITECTURE}" "$IMAGE_TAG"; then
    echo -e "${RED}Error: Failed to pull image${NC}"
    echo "Make sure the image exists and you have access to it"
    exit 1
fi

# Display metadata
echo ""
echo -e "${YELLOW}Cache metadata:${NC}"
docker run --rm --platform "linux/${ARCHITECTURE}" "$IMAGE_TAG" cat /cache/metadata.json | jq .

# Create temporary container to extract files
echo ""
echo -e "${YELLOW}Creating temporary container...${NC}"
CONTAINER_ID=$(docker create --platform "linux/${ARCHITECTURE}" "$IMAGE_TAG")

cleanup() {
  echo ""
  echo -e "${YELLOW}Cleaning up container...${NC}"
  docker rm "$CONTAINER_ID" > /dev/null 2>&1 || true
}

trap cleanup EXIT

# Extract CRC binary
echo ""
echo -e "${YELLOW}Extracting CRC binary...${NC}"
docker cp "$CONTAINER_ID:/cache/crc-binary.tar.xz" ./crc.tar.xz

# Verify the file
FILE_SIZE=$(stat -c%s crc.tar.xz 2> /dev/null || stat -f%z crc.tar.xz 2> /dev/null || echo 0)
if [ "$FILE_SIZE" -lt 1048576 ]; then
  echo -e "${RED}ERROR: Downloaded file is too small ($FILE_SIZE bytes)${NC}"
  exit 1
fi

echo -e "${GREEN}✓ CRC binary downloaded successfully (${FILE_SIZE} bytes)${NC}"

# Extract and install
echo ""
echo -e "${YELLOW}Extracting archive...${NC}"
tar -xvf crc.tar.xz

# Find the CRC binary
CRC_BINARY=""
if [ -d crc-linux-* ] && [ -f crc-linux-*/crc ]; then
  CRC_BINARY=$(find crc-linux-* -name "crc" -type f | head -1)
elif [ -f crc ]; then
  CRC_BINARY="crc"
fi

if [ -z "$CRC_BINARY" ] || [ ! -f "$CRC_BINARY" ]; then
  echo -e "${RED}ERROR: CRC binary not found in extracted archive${NC}"
  exit 1
fi

# Install CRC binary
echo ""
echo -e "${YELLOW}Installing CRC binary...${NC}"
sudo mv "$CRC_BINARY" /usr/local/bin/crc
sudo chmod +x /usr/local/bin/crc

# Verify installation
if command -v crc &> /dev/null; then
    CRC_VERSION=$(crc version 2>/dev/null | head -1 || echo "unknown")
    echo -e "${GREEN}✓ CRC binary installed to /usr/local/bin/crc${NC}"
    echo -e "${GREEN}✓ Version: $CRC_VERSION${NC}"
else
    echo -e "${RED}ERROR: CRC installation verification failed${NC}"
    exit 1
fi

# Extract bundle (optional - uncomment if needed)
echo ""
echo -e "${YELLOW}Extracting CRC bundle...${NC}"
BUNDLE_NAME=$(docker run --rm --platform "linux/${ARCHITECTURE}" "$IMAGE_TAG" cat /cache/bundle_name.txt)
docker cp "$CONTAINER_ID:/cache/bundle.crcbundle" "./${BUNDLE_NAME}"
echo -e "${GREEN}✓ Bundle extracted: ${BUNDLE_NAME}${NC}"
echo -e "${YELLOW}Note: CRC will download the bundle during 'crc setup' if not manually configured${NC}"

# Clean up extracted files
rm -rf crc.tar.xz crc-linux-*

echo ""
echo -e "${GREEN}=== Cache download complete ===${NC}"
echo ""
echo "Next steps:"
echo "  1. Run 'crc setup' to configure CRC"
echo "  2. Run 'crc start' to start your OpenShift cluster"
echo ""
df -h

exit 0

