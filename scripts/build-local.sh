#!/bin/bash
set -e

# Local build script for CRC cache images
# Automatically detects Docker or Podman
# Usage: ./build-local.sh [OCP_VERSION] [--multi-arch] [--push] [--force]
#
# Examples:
#   ./build-local.sh 4.19                           # Build single-arch locally
#   ./build-local.sh 4.19 --multi-arch              # Build multi-arch locally (no push)
#   ./build-local.sh 4.19 --multi-arch --push       # Build and push to Quay
#   ./build-local.sh 4.19 --multi-arch --push --force  # Force rebuild
#   ./build-local.sh --all --multi-arch --push      # Build all versions
#   ./build-local.sh --all --multi-arch --push --force # Force rebuild all

OCP_VERSION="$1"
MULTI_ARCH=false
PUSH=false
BUILD_ALL=false
FORCE=false
REGISTRY="quay.io"
IMAGE_NAME="bapalm/quick-ocp-cache"
CRC_CACHE_DIR="${HOME}/.crc/cache"
BUILD_CACHE_DIR=".build-cache"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Detect container runtime (Docker or Podman)
CONTAINER_RUNTIME=""
if command -v podman &> /dev/null; then
    CONTAINER_RUNTIME="podman"
    echo -e "${GREEN}Detected: Podman${NC}"
elif command -v docker &> /dev/null; then
    CONTAINER_RUNTIME="docker"
    echo -e "${GREEN}Detected: Docker${NC}"
else
    echo -e "${RED}Error: Neither Docker nor Podman found${NC}"
    echo "Please install Docker or Podman to continue"
    exit 1
fi
echo ""

# Parse arguments
shift || true
while [ $# -gt 0 ]; do
    case "$1" in
        --multi-arch)
            MULTI_ARCH=true
            shift
            ;;
        --push)
            PUSH=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        *)
            shift
            ;;
    esac
done

# Check if building all versions
if [ "$OCP_VERSION" == "--all" ]; then
    BUILD_ALL=true
    OCP_VERSION=""
fi

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  CRC Cache Local Build Script${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Ensure .build-cache directory exists (even if empty) for Dockerfile COPY
mkdir -p "$BUILD_CACHE_DIR"

# Function to get CRC version from version-pins.json
get_crc_version_from_pins() {
    local ocp_ver="$1"
    local pins_url="https://raw.githubusercontent.com/palmsoftware/quick-ocp/main/crc-version-pins.json"
    local pinned_version=""
    
    echo -e "${YELLOW}Fetching CRC version pin for OCP ${ocp_ver}...${NC}" >&2
    
    # Try to download and parse the pins file with retry
    local pins_json=""
    local retry_count=0
    local max_retries=3
    
    # Try raw.githubusercontent.com first
    while [ $retry_count -lt $max_retries ]; do
        pins_json=$(curl -s -f --retry 3 --retry-delay 2 "$pins_url" 2>/dev/null)
        if [ $? -eq 0 ] && [ -n "$pins_json" ] && [ "$pins_json" != "404: Not Found" ]; then
            break
        fi
        retry_count=$((retry_count + 1))
        if [ $retry_count -lt $max_retries ]; then
            echo -e "${YELLOW}  Retry $retry_count/$max_retries...${NC}" >&2
            sleep 2
        fi
    done
    
    # Fallback to GitHub API if raw URL failed
    if [ -z "$pins_json" ] || [ "$pins_json" = "404: Not Found" ]; then
        echo -e "${YELLOW}  Trying GitHub API...${NC}" >&2
        local api_url="https://api.github.com/repos/palmsoftware/quick-ocp/contents/crc-version-pins.json"
        local api_response=$(curl -s "$api_url")
        if echo "$api_response" | jq -e '.content' >/dev/null 2>&1; then
            pins_json=$(echo "$api_response" | jq -r '.content' | base64 -d 2>/dev/null || echo "$api_response" | jq -r '.content' | base64 -D 2>/dev/null)
        fi
    fi
    
    if [ $? -eq 0 ] && [ -n "$pins_json" ] && echo "$pins_json" | jq empty 2>/dev/null; then
        # Valid JSON received, try to get the pinned version
        pinned_version=$(echo "$pins_json" | jq -r ".version_pins[\"${ocp_ver}\"]" 2>/dev/null)
        
        if [ "$pinned_version" != "null" ] && [ -n "$pinned_version" ]; then
            echo -e "${BLUE}  Pin for OCP ${ocp_ver}: ${pinned_version}${NC}" >&2
        else
            pinned_version=""
        fi
    fi
    
    # Fallback to hardcoded mappings if pins file not available or version not found
    if [ -z "$pinned_version" ]; then
        echo -e "${YELLOW}  Pins file not available, using hardcoded mapping${NC}" >&2
        case "${ocp_ver}" in
            "4.18") pinned_version="2.51.0" ;;
            "4.19") pinned_version="2.54.0" ;;
            "4.20") pinned_version="2.56.0" ;;
            *) pinned_version="auto" ;;
        esac
        echo -e "${BLUE}  Using fallback version: ${pinned_version}${NC}" >&2
    fi
    
    # If pinned to "auto", fetch latest from GitHub
    if [ "$pinned_version" = "auto" ]; then
        echo -e "${YELLOW}  Fetching latest CRC version from GitHub...${NC}" >&2
        
        # Get all releases and find the one matching this OCP version
        local releases=$(curl -s "https://api.github.com/repos/crc-org/crc/releases")
        
        # Look for release name matching pattern like "2.56.0-4.20.1"
        # The OCP version is in the release name, not the tag
        local matching_release=$(echo "$releases" | jq -r ".[] | select(.name | test(\"^[0-9]+\\\\.[0-9]+\\\\.[0-9]+-${ocp_ver}\\\\.[0-9]+\$\")) | .tag_name" | head -1)
        
        if [ -z "$matching_release" ]; then
            # Fallback: try to get latest release and extract CRC version
            matching_release=$(echo "$releases" | jq -r '.[0].tag_name')
            echo -e "${YELLOW}  Warning: Could not find release specifically for OCP ${ocp_ver}, using latest: ${matching_release}${NC}" >&2
        fi
        
        # Extract CRC version from tag (e.g., "v2.56.0-4.20.1" -> "2.56.0")
        pinned_version=$(echo "$matching_release" | sed -E 's/^v?([0-9]+\.[0-9]+\.[0-9]+).*/\1/')
        
        echo -e "${GREEN}  Auto-resolved to CRC version: ${pinned_version}${NC}" >&2
    fi
    
    # Return the CRC version
    echo "$pinned_version"
}

# Function to check if image already exists (locally or in registry)
check_image_exists() {
    local image_tag="$1"
    local arch="$2"  # optional: check specific arch (amd64 or arm64)
    
    if [ -n "$arch" ]; then
        image_tag="${image_tag}-${arch}"
    fi
    
    # Check locally first
    if $CONTAINER_RUNTIME images --format "{{.Repository}}:{{.Tag}}" | grep -q "^${image_tag}$"; then
        return 0  # exists
    fi
    
    # Check in registry if pushing
    if [ "$PUSH" = true ]; then
        if $CONTAINER_RUNTIME manifest inspect "${image_tag}" &>/dev/null; then
            return 0  # exists in registry
        fi
    fi
    
    return 1  # doesn't exist
}

# Function to find local CRC bundle in ~/.crc/cache
find_local_bundle() {
    local ocp_ver="$1"
    local arch="$2"  # amd64 or arm64
    
    if [ ! -d "$CRC_CACHE_DIR" ]; then
        return 1
    fi
    
    # Look for bundles matching the OCP version and architecture
    # Match both vfkit (macOS) and libvirt (Linux) bundles
    local bundle_file=$(find "$CRC_CACHE_DIR" -type f -name "*${ocp_ver}*${arch}.crcbundle" 2>/dev/null | head -1)
    
    if [ -n "$bundle_file" ] && [ -f "$bundle_file" ]; then
        echo "$bundle_file"
        return 0
    fi
    
    return 1
}

# Function to prepare build cache with local bundles
prepare_build_cache() {
    local ocp_ver="$1"
    
    echo -e "${YELLOW}Checking for local CRC bundles...${NC}"
    
    # Create build cache directory
    mkdir -p "$BUILD_CACHE_DIR"
    
    # Check for bundles for each architecture
    local found_bundles=false
    for arch in amd64 arm64; do
        local bundle_path=$(find_local_bundle "$ocp_ver" "$arch")
        if [ -n "$bundle_path" ] && [ -f "$bundle_path" ]; then
            local bundle_name=$(basename "$bundle_path")
            echo -e "${GREEN}✓ Found local bundle: ${bundle_name}${NC}"
            
            # Copy to build cache with standardized name
            cp "$bundle_path" "$BUILD_CACHE_DIR/bundle-${arch}.crcbundle"
            found_bundles=true
        else
            echo -e "${YELLOW}  No local bundle found for ${arch}${NC}"
        fi
    done
    
    if [ "$found_bundles" = true ]; then
        echo -e "${GREEN}✓ Using local bundles from ${CRC_CACHE_DIR}${NC}"
    else
        echo -e "${YELLOW}  Will download bundles during build${NC}"
    fi
    echo ""
}

# Function to save downloaded bundles to CRC cache
save_to_crc_cache() {
    local image_tag="$1"
    local ocp_ver="$2"
    
    echo -e "${YELLOW}Checking if bundle should be saved to CRC cache...${NC}"
    
    # Create CRC cache directory if it doesn't exist
    mkdir -p "$CRC_CACHE_DIR"
    
    # Extract bundle metadata from image to check if we downloaded a new one
    local container_id=$($CONTAINER_RUNTIME create "$image_tag" 2>/dev/null || echo "")
    if [ -z "$container_id" ]; then
        echo -e "${YELLOW}  Could not create container to extract bundle${NC}"
        return
    fi
    
    # Get bundle name
    $CONTAINER_RUNTIME cp "${container_id}:/cache/bundle_name.txt" "/tmp/bundle_name-${ocp_ver}.txt" 2>/dev/null
    
    if [ -f "/tmp/bundle_name-${ocp_ver}.txt" ]; then
        local bundle_name=$(cat "/tmp/bundle_name-${ocp_ver}.txt")
        local dest_path="${CRC_CACHE_DIR}/${bundle_name}"
        
        if [ ! -f "$dest_path" ]; then
            echo -e "${YELLOW}  Extracting bundle from image...${NC}"
            $CONTAINER_RUNTIME cp "${container_id}:/cache/bundle.crcbundle" "$dest_path" 2>/dev/null
            if [ -f "$dest_path" ]; then
                echo -e "${GREEN}✓ Saved bundle to: ${dest_path}${NC}"
                echo -e "${GREEN}  (Can be reused by CRC and future builds)${NC}"
            fi
        else
            echo -e "${GREEN}✓ Bundle already exists in cache${NC}"
        fi
        rm "/tmp/bundle_name-${ocp_ver}.txt" 2>/dev/null
    fi
    
    $CONTAINER_RUNTIME rm "$container_id" > /dev/null 2>&1
    echo ""
}

# Function to build a single version
build_version() {
    local ocp_ver="$1"
    
    # Get CRC version from pins
    local crc_ver=$(get_crc_version_from_pins "$ocp_ver")
    if [ $? -ne 0 ] || [ -z "$crc_ver" ]; then
        echo -e "${RED}Failed to determine CRC version for OCP ${ocp_ver}${NC}"
        return 1
    fi
    
    # Use CRC version as the image tag
    local image_tag="${REGISTRY}/${IMAGE_NAME}:${crc_ver}"
    
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${YELLOW}Building for OCP ${ocp_ver} → CRC ${crc_ver}${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo "Image: ${image_tag}"
    echo "OCP Version: ${ocp_ver}"
    echo "CRC Version: ${crc_ver}"
    echo "Multi-arch: ${MULTI_ARCH}"
    echo "Push: ${PUSH}"
    echo "Force: ${FORCE}"
    echo ""
    
    # Check if images already exist (unless --force is specified)
    if [ "$FORCE" = false ]; then
        local skip_build=false
        
        if [ "$MULTI_ARCH" = true ]; then
            # Check both amd64 and arm64
            if check_image_exists "${image_tag}" "amd64" && check_image_exists "${image_tag}" "arm64"; then
                echo -e "${GREEN}✓ Images already exist for CRC ${crc_ver} (OCP ${ocp_ver}) - amd64 + arm64${NC}"
                echo -e "${YELLOW}  Skipping build. Use --force to rebuild.${NC}"
                echo ""
                skip_build=true
            fi
        else
            # Check single arch
            if check_image_exists "${image_tag}"; then
                echo -e "${GREEN}✓ Image already exists for CRC ${crc_ver} (OCP ${ocp_ver})${NC}"
                echo -e "${YELLOW}  Skipping build. Use --force to rebuild.${NC}"
                echo ""
                skip_build=true
            fi
        fi
        
        if [ "$skip_build" = true ]; then
            return 0
        fi
    else
        echo -e "${YELLOW}Force rebuild enabled - will rebuild even if images exist${NC}"
        echo ""
    fi
    
    # Prepare build cache with local bundles if available
    prepare_build_cache "$ocp_ver"
    
    if [ "$MULTI_ARCH" = true ]; then
        # Multi-architecture build (requires buildx)
        echo -e "${YELLOW}Setting up buildx...${NC}"
        
        if [ "$CONTAINER_RUNTIME" = "podman" ]; then
            # Podman multi-arch build using manifest
            echo -e "${YELLOW}Building multi-arch with Podman manifest...${NC}"
            echo -e "${YELLOW}Strategy: Build → Push → Cleanup each arch to save disk space${NC}"
            echo ""
            
            if [ "$PUSH" = true ]; then
                # Build and push amd64, then clean up to save space
                echo -e "${BLUE}=== Building amd64 architecture ===${NC}"
                echo -e "${YELLOW}Note: Large bundle downloads (~5-6 GB) will take 10-20 minutes${NC}"
                echo ""
                $CONTAINER_RUNTIME build \
                    --platform linux/amd64 \
                    --build-arg OCP_VERSION="${ocp_ver}" \
                    --label ocp_version="${ocp_ver}" \
                    --label crc_version="${crc_ver}" \
                    --progress=plain \
                    -t "${image_tag}-amd64" \
                    .
                echo ""
                echo -e "${GREEN}✓ amd64 build complete${NC}"
                echo ""
                
                echo -e "${BLUE}Pushing amd64 image...${NC}"
                $CONTAINER_RUNTIME push "${image_tag}-amd64"
                echo ""
                echo -e "${GREEN}✓ amd64 pushed${NC}"
                echo ""
                
                echo -e "${YELLOW}Cleaning up amd64 image to free space...${NC}"
                $CONTAINER_RUNTIME rmi "${image_tag}-amd64" || true
                echo ""
                
                # Build and push arm64, then clean up to save space
                echo -e "${BLUE}=== Building arm64 architecture ===${NC}"
                echo -e "${YELLOW}Note: Large bundle downloads (~5-6 GB) will take 10-20 minutes${NC}"
                echo ""
                $CONTAINER_RUNTIME build \
                    --platform linux/arm64 \
                    --build-arg OCP_VERSION="${ocp_ver}" \
                    --label ocp_version="${ocp_ver}" \
                    --label crc_version="${crc_ver}" \
                    --progress=plain \
                    -t "${image_tag}-arm64" \
                    .
                echo ""
                echo -e "${GREEN}✓ arm64 build complete${NC}"
                echo ""
                
                echo -e "${BLUE}Pushing arm64 image...${NC}"
                $CONTAINER_RUNTIME push "${image_tag}-arm64"
                echo ""
                echo -e "${GREEN}✓ arm64 pushed${NC}"
                echo ""
                
                echo -e "${YELLOW}Cleaning up arm64 image to free space...${NC}"
                $CONTAINER_RUNTIME rmi "${image_tag}-arm64" || true
                echo ""
                
                # Create and push manifest (pulls manifests, not full images)
                echo -e "${BLUE}Creating multi-arch manifest...${NC}"
                $CONTAINER_RUNTIME manifest create "${image_tag}" \
                    "${image_tag}-amd64" \
                    "${image_tag}-arm64"
                echo ""
                
                echo -e "${BLUE}Pushing manifest...${NC}"
                $CONTAINER_RUNTIME manifest push "${image_tag}"
                echo ""
                echo -e "${GREEN}✓ Multi-arch manifest complete${NC}"
                echo ""
            else
                # Build both but don't push (still need both locally)
                echo -e "${YELLOW}Note: Local builds require ~12GB+ disk space${NC}"
                echo ""
                
                echo -e "${BLUE}=== Building amd64 architecture ===${NC}"
                echo -e "${YELLOW}Note: Large bundle downloads (~5-6 GB) will take 10-20 minutes${NC}"
                echo ""
                $CONTAINER_RUNTIME build \
                    --platform linux/amd64 \
                    --build-arg OCP_VERSION="${ocp_ver}" \
                    --label ocp_version="${ocp_ver}" \
                    --label crc_version="${crc_ver}" \
                    --progress=plain \
                    -t "${image_tag}-amd64" \
                    .
                echo ""
                echo -e "${GREEN}✓ amd64 build complete${NC}"
                echo ""
                
                echo -e "${BLUE}=== Building arm64 architecture ===${NC}"
                echo -e "${YELLOW}Note: Large bundle downloads (~5-6 GB) will take 10-20 minutes${NC}"
                echo ""
                $CONTAINER_RUNTIME build \
                    --platform linux/arm64 \
                    --build-arg OCP_VERSION="${ocp_ver}" \
                    --label ocp_version="${ocp_ver}" \
                    --label crc_version="${crc_ver}" \
                    --progress=plain \
                    -t "${image_tag}-arm64" \
                    .
                echo ""
                echo -e "${GREEN}✓ arm64 build complete${NC}"
                echo ""
                
                echo -e "${YELLOW}Note: Multi-arch images built but not pushed${NC}"
                echo "Available as: ${image_tag}-amd64 and ${image_tag}-arm64"
            fi
        else
            # Docker buildx
            # Check if builder exists, create if not
            if ! $CONTAINER_RUNTIME buildx inspect multiarch > /dev/null 2>&1; then
                echo "Creating buildx builder 'multiarch'..."
                $CONTAINER_RUNTIME buildx create --name multiarch --use
                $CONTAINER_RUNTIME buildx inspect --bootstrap
            else
                $CONTAINER_RUNTIME buildx use multiarch
            fi
            
            echo ""
            if [ "$PUSH" = true ]; then
                echo -e "${BLUE}=== Building multi-arch image (amd64 + arm64) ===${NC}"
                echo -e "${YELLOW}Note: Large bundle downloads (~5-6 GB per arch) will take 20-40 minutes${NC}"
                echo ""
                $CONTAINER_RUNTIME buildx build \
                    --platform linux/amd64,linux/arm64 \
                    --build-arg OCP_VERSION="${ocp_ver}" \
                    --label ocp_version="${ocp_ver}" \
                    --label crc_version="${crc_ver}" \
                    --progress=plain \
                    -t "${image_tag}" \
                    --push \
                    .
            else
                echo -e "${BLUE}=== Building multi-arch image (amd64 + arm64) ===${NC}"
                echo -e "${YELLOW}Note: Large bundle downloads (~5-6 GB per arch) will take 20-40 minutes${NC}"
                echo ""
                $CONTAINER_RUNTIME buildx build \
                    --platform linux/amd64,linux/arm64 \
                    --build-arg OCP_VERSION="${ocp_ver}" \
                    --label ocp_version="${ocp_ver}" \
                    --label crc_version="${crc_ver}" \
                    --progress=plain \
                    -t "${image_tag}" \
                    --load \
                    .
            fi
            echo ""
            echo -e "${GREEN}✓ Multi-arch build complete${NC}"
            echo ""
        fi
    else
        # Single architecture build (current platform)
        echo -e "${BLUE}=== Building single-arch image for current platform ===${NC}"
        echo -e "${YELLOW}Note: Large bundle download (~5-6 GB) will take 10-20 minutes${NC}"
        echo ""
        $CONTAINER_RUNTIME build \
            --build-arg OCP_VERSION="${ocp_ver}" \
            --label ocp_version="${ocp_ver}" \
            --label crc_version="${crc_ver}" \
            --progress=plain \
            -t "${image_tag}" \
            .
        echo ""
        echo -e "${GREEN}✓ Build complete${NC}"
        echo ""
        
        if [ "$PUSH" = true ]; then
            echo -e "${YELLOW}Pushing image to registry...${NC}"
            $CONTAINER_RUNTIME push "${image_tag}"
            echo ""
            echo -e "${GREEN}✓ Push complete${NC}"
            echo ""
        fi
    fi
    
    # Save downloaded bundle to CRC cache (if not already there)
    save_to_crc_cache "${image_tag}" "${ocp_ver}"
    
    # Clean up build cache directory
    rm -rf "$BUILD_CACHE_DIR"
    
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}✓ Build complete for CRC ${crc_ver} (OCP ${ocp_ver})${NC}"
    echo -e "${GREEN}  Image: ${image_tag}${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
}

# Check if logged in to Quay when pushing
if [ "$PUSH" = true ]; then
    echo -e "${YELLOW}Checking Quay.io authentication...${NC}"
    
    # Check if already logged in (method varies between docker/podman)
    LOGIN_NEEDED=false
    if [ "$CONTAINER_RUNTIME" = "podman" ]; then
        if ! $CONTAINER_RUNTIME login --get-login quay.io 2>/dev/null; then
            LOGIN_NEEDED=true
        fi
    else
        if ! $CONTAINER_RUNTIME info 2>/dev/null | grep -q "quay.io"; then
            LOGIN_NEEDED=true
        fi
    fi
    
    if [ "$LOGIN_NEEDED" = true ]; then
        echo -e "${YELLOW}Not logged in to Quay.io. Logging in...${NC}"
        $CONTAINER_RUNTIME login quay.io
    else
        echo -e "${GREEN}Already logged in to Quay.io${NC}"
    fi
    echo ""
fi

# Build single version or all versions
if [ "$BUILD_ALL" = true ]; then
    echo -e "${BLUE}Building all versions from ocp-versions.json...${NC}"
    echo ""
    
    if [ ! -f ocp-versions.json ]; then
        echo -e "${RED}Error: ocp-versions.json not found${NC}"
        exit 1
    fi
    
    VERSIONS=$(jq -r '.versions[]' ocp-versions.json)
    
    for ver in $VERSIONS; do
        build_version "$ver"
    done
else
    if [ -z "$OCP_VERSION" ]; then
        echo -e "${RED}Error: OCP version required${NC}"
        echo ""
        echo "Usage: $0 [OCP_VERSION] [--multi-arch] [--push] [--force]"
        echo ""
        echo "Examples:"
        echo "  $0 4.19                           # Build single-arch locally"
        echo "  $0 4.19 --multi-arch              # Build multi-arch locally"
        echo "  $0 4.19 --multi-arch --push       # Build and push to Quay"
        echo "  $0 4.19 --multi-arch --push --force  # Force rebuild"
        echo "  $0 --all --multi-arch --push      # Build all versions"
        echo "  $0 --all --multi-arch --push --force # Force rebuild all"
        exit 1
    fi
    
    build_version "$OCP_VERSION"
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Build Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

if [ "$PUSH" = false ]; then
    echo -e "${YELLOW}Images built locally (not pushed to registry)${NC}"
    echo "Images are tagged by CRC version (e.g., 2.54.0)"
    echo "To test: ${CONTAINER_RUNTIME} images | grep ${IMAGE_NAME}"
else
    echo -e "${GREEN}Images pushed to ${REGISTRY}/${IMAGE_NAME}${NC}"
    echo "Images are tagged by CRC version (e.g., 2.54.0, 2.56.0)"
    echo "To pull: ${CONTAINER_RUNTIME} pull ${REGISTRY}/${IMAGE_NAME}:<CRC_VERSION>"
fi

