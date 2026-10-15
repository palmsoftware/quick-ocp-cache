#!/bin/bash

# Resolve the CRC release that serves a given OCP minor version.
#
# Mirrors the runtime resolution in quick-ocp's scripts/fetch-ocp-crc-version.sh
# (same release-list fields, same newest-by-published ordering) so cache images
# are built from the same CRC release the action would download at deploy time.
#
# The GitHub release name encodes both versions ("2.57.0-4.20.5" = CRC version +
# the OpenShift z-version that release embeds); the release body is the fallback
# source. The z-version is what `crc setup` expects a pre-seeded bundle to be
# named after, so it is returned alongside the CRC version.
#
# Usage: resolve-crc-release.sh --minor 4.20 [--pin auto|2.57.0]
#
# Output: "<crc_version>\t<bundle_version>" on stdout (e.g. "2.57.0\t4.20.5"),
#         or no output (exit 0) when no release serves the requested minor.
#         A nonzero exit means the release list could not be obtained or parsed.
#
# Environment:
#   RELEASES_FILE  Optional path to a cached GitHub API response of
#                  /repos/crc-org/crc/releases?per_page=100. When unset the
#                  script fetches the list itself.
#   GITHUB_TOKEN   Optional token for the GitHub API request.

set -euo pipefail

GITHUB_API_RELEASES_URL="https://api.github.com/repos/crc-org/crc/releases?per_page=100"

usage() {
    echo "Usage: $0 --minor <X.Y> [--pin auto|<crc-version>]" >&2
}

MINOR=""
PIN="auto"
while [ $# -gt 0 ]; do
    case "$1" in
        --minor)
            MINOR="${2:-}"
            shift 2
            ;;
        --pin)
            PIN="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage
            exit 2
            ;;
    esac
done

if ! [[ "${MINOR}" =~ ^[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: --minor is required and must look like 4.20 (got: '${MINOR}')" >&2
    usage
    exit 2
fi

if [ "${PIN}" != "auto" ] && ! [[ "${PIN}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: --pin must be 'auto' or a CRC version like 2.57.0 (got: '${PIN}')" >&2
    exit 2
fi

if [ -n "${RELEASES_FILE:-}" ] && [ -s "${RELEASES_FILE}" ]; then
    RELEASES=$(cat "${RELEASES_FILE}")
else
    AUTH_ARGS=()
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        AUTH_ARGS=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
    fi
    RELEASES=$(curl -fsSL --retry 5 --retry-delay 3 \
        ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} \
        "${GITHUB_API_RELEASES_URL}")
fi

if ! printf '%s' "${RELEASES}" | jq -e 'type == "array"' > /dev/null; then
    echo "ERROR: release list is not a JSON array (API error or rate limit?)" >&2
    exit 1
fi

# Selection logic (kept in sync with quick-ocp's fetch-ocp-crc-version.sh):
# - extract the served OpenShift version from the release name suffix or body
# - keep only releases serving the requested minor
# - order by published date, newest first
# - auto: take the newest; explicit pin: take that exact release
printf '%s' "${RELEASES}" | jq -r \
    --arg minor "${MINOR}" --arg pin "${PIN}" '
    [
      .[]
      | {
          tag: (.tag_name // "" | sub("^v"; "")),
          published: .published_at,
          ocp: (
            if ((.name // "") | test("-[0-9]+\\.[0-9]+\\.[0-9]+$")) then
              (.name | capture("-(?<ver>[0-9]+\\.[0-9]+\\.[0-9]+)$") | .ver)
            elif ((.body // "") | test("OpenShift\\s+[0-9]+\\.[0-9]+\\.[0-9]+")) then
              (.body | capture("OpenShift\\s+(?<ver>[0-9]+\\.[0-9]+\\.[0-9]+)") | .ver)
            else
              null
            end
          )
        }
      | select(.ocp != null)
      | select(.ocp | startswith($minor + "."))
    ]
    | sort_by(.published)
    | reverse
    | (if $pin == "auto" then .[0] else ([.[] | select(.tag == $pin)] | .[0]) end)
    | if . == null then empty else ([.tag, .ocp] | @tsv) end
    '
