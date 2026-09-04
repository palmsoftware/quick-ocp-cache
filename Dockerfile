# Multi-stage Dockerfile for caching CRC binary and bundle
# Supports multiple OCP versions and architectures
# Usage: docker build --build-arg OCP_VERSION=4.19 -t quick-ocp-cache:4.19 .

FROM --platform=$BUILDPLATFORM registry.access.redhat.com/ubi9/ubi-minimal:latest AS downloader

ARG OCP_VERSION
ARG TARGETARCH
ARG CRC_VERSION
ARG CRC_MIRROR_URL=https://mirror.openshift.com/pub/openshift-v4/clients/crc
ARG BUNDLE_MIRROR_URL=https://mirror.openshift.com/pub/openshift-v4/clients/crc/bundles/openshift

# Install dependencies (curl will replace curl-minimal automatically)
# Note: UBI9-minimal comes with curl-minimal, but we need full curl for --retry flag support
RUN microdnf install -y curl tar gzip jq && microdnf clean all || \
    (rpm -e --nodeps curl-minimal && microdnf install -y curl tar gzip jq && microdnf clean all)

WORKDIR /cache

# Determine CRC version — prefer the explicit build arg passed by CI.
# Falls back to a hardcoded mapping or GitHub API for local builds.
# See: https://github.com/crc-org/crc/releases
RUN echo "Determining CRC version for OCP ${OCP_VERSION}..." && \
    if [ -n "${CRC_VERSION}" ]; then \
        echo "Using explicit CRC_VERSION build arg: ${CRC_VERSION}"; \
    else \
        case "${OCP_VERSION}" in \
            "4.18") CRC_VERSION="2.51.0" ;; \
            "4.19") CRC_VERSION="2.54.0" ;; \
            "4.20") CRC_VERSION="2.56.0" ;; \
            *) echo "Fetching latest CRC version for OCP ${OCP_VERSION}..."; \
               CRC_VERSION=$(curl -s "https://api.github.com/repos/crc-org/crc/releases/latest" | \
                            jq -r '.tag_name | ltrimstr("v")') ;; \
        esac; \
    fi && \
    echo "${CRC_VERSION}" > /cache/crc_version.txt && \
    echo "Using CRC version: ${CRC_VERSION}"

# Determine architecture-specific binary name
RUN case "${TARGETARCH}" in \
        "amd64") ARCH_NAME="linux-amd64" ;; \
        "arm64") ARCH_NAME="linux-arm64" ;; \
        *) echo "Unsupported architecture: ${TARGETARCH}"; exit 1 ;; \
    esac && \
    echo "${ARCH_NAME}" > /cache/arch_name.txt

# Download CRC binary
RUN CRC_VERSION=$(cat /cache/crc_version.txt) && \
    ARCH_NAME=$(cat /cache/arch_name.txt) && \
    BINARY_NAME="crc-${ARCH_NAME}.tar.xz" && \
    echo "Downloading CRC binary: ${BINARY_NAME} (version ${CRC_VERSION})..." && \
    curl -L -f --retry 3 --retry-delay 5 \
        -o "/cache/crc-binary.tar.xz" \
        "${CRC_MIRROR_URL}/${CRC_VERSION}/${BINARY_NAME}" && \
    echo "Download complete. Size: $(stat -c%s /cache/crc-binary.tar.xz 2>/dev/null || stat -f%z /cache/crc-binary.tar.xz) bytes" && \
    echo "${BINARY_NAME}" > /cache/binary_name.txt

# Create directory for optional local bundles (populated by build-local.sh)
RUN mkdir -p /build-cache

# Copy local bundles from build cache if available
# During CI builds, this directory will be empty (which is fine)
COPY .build-cache /build-cache

# Download CRC bundle - use local cache if available, otherwise download
RUN CRC_VERSION=$(cat /cache/crc_version.txt) && \
    ARCH_NAME=$(cat /cache/arch_name.txt) && \
    echo "Discovering bundle file for OCP ${OCP_VERSION} (CRC ${CRC_VERSION})..." && \
    BUNDLE_FOUND=false && \
    \
    # Check for local bundle first (from build-local.sh cache)
    if [ "${TARGETARCH}" = "amd64" ] && [ -f "/build-cache/bundle-amd64.crcbundle" ]; then \
        echo "Using local cached bundle for amd64" && \
        cp /build-cache/bundle-amd64.crcbundle /cache/bundle.crcbundle && \
        BUNDLE_FILE="bundle-amd64.crcbundle" && \
        echo "crc_libvirt_${OCP_VERSION}_amd64.crcbundle" > /cache/bundle_name.txt && \
        BUNDLE_FOUND=true; \
    elif [ "${TARGETARCH}" = "arm64" ] && [ -f "/build-cache/bundle-arm64.crcbundle" ]; then \
        echo "Using local cached bundle for arm64" && \
        cp /build-cache/bundle-arm64.crcbundle /cache/bundle.crcbundle && \
        BUNDLE_FILE="bundle-arm64.crcbundle" && \
        echo "crc_vfkit_${OCP_VERSION}_arm64.crcbundle" > /cache/bundle_name.txt && \
        BUNDLE_FOUND=true; \
    fi && \
    \
    # If no local bundle, download from mirror
    if [ "$BUNDLE_FOUND" = false ]; then \
        # Try new bundle location first - find latest patch version for this OCP major.minor
        echo "No local bundle found, downloading from mirror..." && \
        echo "Trying new bundle location: ${BUNDLE_MIRROR_URL}/" && \
    LATEST_PATCH=$(curl -s "${BUNDLE_MIRROR_URL}/" 2>/dev/null | \
        grep -oE "/${OCP_VERSION}\.[0-9]+/" | \
        grep -oE "${OCP_VERSION}\.[0-9]+" | \
        sort -V | tail -1 || true) && \
    \
    if [ -n "$LATEST_PATCH" ]; then \
        echo "Found OCP patch version: ${LATEST_PATCH}" && \
        BUNDLE_URL="${BUNDLE_MIRROR_URL}/${LATEST_PATCH}/" && \
        BUNDLE_FILE=$(curl -s "${BUNDLE_URL}" 2>/dev/null | \
            grep -oE "crc_(libvirt|vfkit)_[0-9.]+_${TARGETARCH}\.crcbundle" | head -1 || true) && \
        \
        if [ -n "$BUNDLE_FILE" ]; then \
            echo "Found bundle in new location: ${BUNDLE_FILE}" && \
            curl -L -f --retry 3 --retry-delay 5 \
                -o "/cache/bundle.crcbundle" \
                "${BUNDLE_URL}${BUNDLE_FILE}" && \
            BUNDLE_FOUND=true; \
        fi; \
    fi && \
    \
        # Fall back to old location if new location didn't work
        if [ "$BUNDLE_FOUND" = false ]; then \
            echo "Bundle not found in new location, trying old location..." && \
            OLD_BUNDLE_URL="${CRC_MIRROR_URL}/${CRC_VERSION}" && \
            echo "Trying: ${OLD_BUNDLE_URL}/" && \
            BUNDLE_FILE=$(curl -s "${OLD_BUNDLE_URL}/" | \
                grep -oE 'crc_libvirt_[0-9.]+\.crcbundle' | head -1) && \
            \
            if [ -n "$BUNDLE_FILE" ]; then \
                echo "Found bundle in old location: ${BUNDLE_FILE}" && \
                curl -L -f --retry 3 --retry-delay 5 \
                    -o "/cache/bundle.crcbundle" \
                    "${OLD_BUNDLE_URL}/${BUNDLE_FILE}" && \
                BUNDLE_FOUND=true; \
            fi; \
        fi && \
        \
        echo "${BUNDLE_FILE}" > /cache/bundle_name.txt; \
    fi && \
    \
    # Final check
    if [ "$BUNDLE_FOUND" = false ] || [ ! -f "/cache/bundle.crcbundle" ]; then \
        echo "ERROR: Could not find bundle file for OCP ${OCP_VERSION} / CRC ${CRC_VERSION}"; \
        exit 1; \
    fi && \
    \
    echo "Bundle download complete. Size: $(stat -c%s /cache/bundle.crcbundle 2>/dev/null || stat -f%z /cache/bundle.crcbundle) bytes"

# Wrap bundle in a tar preserving the original versioned filename.
# Consumers extract with: tar -xf bundle.tar -C ~/.crc/cache/
RUN BUNDLE_FILE=$(cat /cache/bundle_name.txt) && \
    cp /cache/bundle.crcbundle "/cache/${BUNDLE_FILE}" && \
    tar -cf /cache/bundle.tar -C /cache "${BUNDLE_FILE}" && \
    rm /cache/bundle.crcbundle "/cache/${BUNDLE_FILE}"

# Create metadata file
RUN CRC_VERSION=$(cat /cache/crc_version.txt) && \
    BINARY_NAME=$(cat /cache/binary_name.txt) && \
    BUNDLE_NAME=$(cat /cache/bundle_name.txt) && \
    ARCH_NAME=$(cat /cache/arch_name.txt) && \
    cat > /cache/metadata.json <<EOF
{
  "ocp_version": "${OCP_VERSION}",
  "crc_version": "${CRC_VERSION}",
  "architecture": "${TARGETARCH}",
  "binary_name": "${BINARY_NAME}",
  "bundle_name": "${BUNDLE_NAME}",
  "binary_size": $(stat -c%s /cache/crc-binary.tar.xz 2>/dev/null || stat -f%z /cache/crc-binary.tar.xz),
  "bundle_size": $(stat -c%s /cache/bundle.tar 2>/dev/null || stat -f%z /cache/bundle.tar),
  "build_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "mirror_url": "${CRC_MIRROR_URL}/${CRC_VERSION}",
  "bundle_url": "${BUNDLE_MIRROR_URL}/${OCP_VERSION}"
}
EOF

# Verify downloads
RUN ls -lh /cache && \
    test -f /cache/crc-binary.tar.xz || (echo "ERROR: CRC binary missing" && exit 1) && \
    test -f /cache/bundle.tar || (echo "ERROR: Bundle missing" && exit 1) && \
    test -f /cache/metadata.json || (echo "ERROR: Metadata missing" && exit 1)

# Final minimal image
FROM registry.access.redhat.com/ubi9/ubi-minimal:latest

ARG OCP_VERSION
ARG TARGETARCH

LABEL name="quick-ocp-cache" \
      ocp_version="${OCP_VERSION}" \
      architecture="${TARGETARCH}" \
      description="Cached CRC binary and bundle for OCP ${OCP_VERSION}" \
      maintainer="Brandon Palm <bpalm@redhat.com>" \
      source="https://github.com/palmsoftware/quick-ocp-cache"

RUN microdnf install -y tar gzip && microdnf clean all

WORKDIR /cache

# Copy downloaded files from builder
COPY --from=downloader /cache/crc-binary.tar.xz .
COPY --from=downloader /cache/bundle.tar .
COPY --from=downloader /cache/bundle_name.txt .
COPY --from=downloader /cache/binary_name.txt .
COPY --from=downloader /cache/crc_version.txt .
COPY --from=downloader /cache/arch_name.txt .
COPY --from=downloader /cache/metadata.json .

# Create extraction script
RUN printf '%s\n' \
    '#!/bin/bash' \
    'set -e' \
    '' \
    'DEST_DIR="${1:-.}"' \
    'echo "=== Extracting CRC cache to ${DEST_DIR} ==="' \
    '' \
    '# Display metadata' \
    'if [ -f /cache/metadata.json ]; then' \
    '    echo "Cache metadata:"' \
    '    cat /cache/metadata.json | grep -E '"'"'"ocp_version"|"crc_version"|"architecture"'"'"'' \
    '    echo ""' \
    'fi' \
    '' \
    '# Extract CRC binary' \
    'echo "Extracting CRC binary..."' \
    'tar -xvf /cache/crc-binary.tar.xz -C "${DEST_DIR}"' \
    'echo "✓ CRC binary extracted"' \
    '' \
    '# Extract bundle (tar preserves original versioned filename)' \
    'mkdir -p "${DEST_DIR}/bundle"' \
    'tar -xf /cache/bundle.tar -C "${DEST_DIR}/bundle/"' \
    'echo "✓ Bundle extracted to ${DEST_DIR}/bundle/"' \
    '' \
    'echo "=== Extraction complete! ==="' \
    'ls -lh "${DEST_DIR}"' \
    > /cache/extract.sh && \
    chmod +x /cache/extract.sh

# Verify and display metadata
RUN ls -lh /cache && \
    echo "=== CRC Cache Image Built ===" && \
    cat /cache/metadata.json && \
    echo "============================"

CMD ["/bin/bash", "-c", "cat /cache/metadata.json && echo '' && ls -lh /cache"]

