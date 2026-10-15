#!/bin/bash

# Decide whether a cache image tag needs rebuilding by comparing the labels of
# the image currently in the registry against the desired versions.
#
# Replaces the old "skip if the tag exists" check: an existing tag can hold a
# stale image (wrong CRC release or wrong bundle z-version for the current
# pins), which is exactly the drift this repository exists to avoid.
#
# Usage: check-image-drift.sh   (all configuration via environment)
#
# Environment:
#   REPOSITORY          Repository path (e.g. bapalm/quick-ocp-cache) — required
#   TAG                 Image tag to check (e.g. 4.20-amd64) — required
#   DESIRED_CRC_VERSION crc_version the image must carry — required
#   DESIRED_BUNDLE_VERSION bundle_version the image must carry; optional —
#                       when empty only crc_version is compared
#   FORCE_REBUILD       "true" to rebuild unconditionally (default: false)
#   REGISTRY            Registry host (default: quay.io)
#
# Output: "rebuilt=true" (rebuild needed) or "rebuilt=false" (image is
#         current), written to $GITHUB_OUTPUT when set, otherwise stdout.
#         Always exits 0 — any lookup failure fails open to a rebuild so a
#         registry hiccup can never wedge the weekly build into permanent skip.

set -euo pipefail

REGISTRY="${REGISTRY:-quay.io}"
REPOSITORY="${REPOSITORY:?REPOSITORY env var is required}"
TAG="${TAG:?TAG env var is required}"
DESIRED_CRC_VERSION="${DESIRED_CRC_VERSION:?DESIRED_CRC_VERSION env var is required}"
DESIRED_BUNDLE_VERSION="${DESIRED_BUNDLE_VERSION:-}"
FORCE_REBUILD="${FORCE_REBUILD:-false}"

emit() {
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        echo "rebuilt=$1" >> "${GITHUB_OUTPUT}"
    else
        echo "rebuilt=$1"
    fi
}

fail_open() {
    echo "::warning::$1 — defaulting to rebuild"
    emit true
    exit 0
}

if [ "${FORCE_REBUILD}" = "true" ]; then
    echo "Force rebuild requested"
    emit true
    exit 0
fi

# Anonymous pull token for the repository
TOKEN=$(curl -fsSL \
    "https://${REGISTRY}/v2/auth?service=${REGISTRY}&scope=repository:${REPOSITORY}:pull" \
    | jq -r '.token // empty') || fail_open "Could not obtain registry token"
if [ -z "${TOKEN}" ]; then
    fail_open "Registry returned no token"
fi

MANIFEST=$(curl -fsSL \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
    -H "Accept: application/vnd.oci.image.manifest.v1+json" \
    "https://${REGISTRY}/v2/${REPOSITORY}/manifests/${TAG}") \
    || fail_open "Could not fetch manifest for ${REPOSITORY}:${TAG} (missing tag?)"

CONFIG_DIGEST=$(printf '%s' "${MANIFEST}" | jq -r '.config.digest // empty')
if [ -z "${CONFIG_DIGEST}" ]; then
    fail_open "Manifest for ${REPOSITORY}:${TAG} has no config digest"
fi

# Blob GETs redirect to the CDN; -L follows. The Authorization header is
# dropped automatically on the cross-host redirect, which the CDN accepts.
CONFIG=$(curl -fsSL \
    -H "Authorization: Bearer ${TOKEN}" \
    "https://${REGISTRY}/v2/${REPOSITORY}/blobs/${CONFIG_DIGEST}") \
    || fail_open "Could not fetch config blob for ${REPOSITORY}:${TAG}"

ACTUAL_CRC=$(printf '%s' "${CONFIG}" | jq -r '.config.Labels.crc_version // empty')
ACTUAL_BUNDLE=$(printf '%s' "${CONFIG}" | jq -r '.config.Labels.bundle_version // empty')

if [ "${ACTUAL_CRC}" = "${DESIRED_CRC_VERSION}" ]; then
    if [ -z "${DESIRED_BUNDLE_VERSION}" ] || [ "${ACTUAL_BUNDLE}" = "${DESIRED_BUNDLE_VERSION}" ]; then
        echo "Image ${REPOSITORY}:${TAG} is current (crc_version=${ACTUAL_CRC}, bundle_version=${ACTUAL_BUNDLE:-<unchecked>})"
        emit false
        exit 0
    fi
fi

echo "Image ${REPOSITORY}:${TAG} is stale — rebuild needed:"
echo "  desired: crc_version=${DESIRED_CRC_VERSION}, bundle_version=${DESIRED_BUNDLE_VERSION:-<unchecked>}"
echo "  actual:  crc_version=${ACTUAL_CRC:-<none>}, bundle_version=${ACTUAL_BUNDLE:-<none>}"
emit true
