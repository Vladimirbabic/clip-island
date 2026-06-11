#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEAM_ID="${TEAM_ID:-DY4JMWWW5S}"
SCHEME="${SCHEME:-ClipStory-iOS}"
ARCHIVE_DIR="${ROOT_DIR}/build/archives"
ARCHIVE_PATH="${ARCHIVE_DIR}/${SCHEME}.xcarchive"
EXPORT_DIR="${ROOT_DIR}/build/testflight"
EXPORT_OPTIONS="${ROOT_DIR}/scripts/exportOptions.testflight.plist"
XCODE_AUTH_KEY_PATH="${XCODE_AUTH_KEY_PATH:-${ASC_API_KEY_PATH:-}}"
XCODE_AUTH_KEY_ID="${XCODE_AUTH_KEY_ID:-${ASC_API_KEY_ID:-}}"
XCODE_AUTH_KEY_ISSUER_ID="${XCODE_AUTH_KEY_ISSUER_ID:-${ASC_API_KEY_ISSUER_ID:-}}"

fail() {
  echo "error: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

require_cmd awk
require_cmd xcodebuild
require_cmd xcrun

if [[ "${TEAM_ID}" != "DY4JMWWW5S" ]]; then
  fail "Refusing to upload with TEAM_ID=${TEAM_ID}; expected DY4JMWWW5S."
fi

XCODE_AUTH_ARGS=()
if [[ -n "${XCODE_AUTH_KEY_PATH}${XCODE_AUTH_KEY_ID}${XCODE_AUTH_KEY_ISSUER_ID}" ]]; then
  [[ -n "${XCODE_AUTH_KEY_PATH}" ]] || fail "Set XCODE_AUTH_KEY_PATH when using Xcode API-key signing."
  [[ -n "${XCODE_AUTH_KEY_ID}" ]] || fail "Set XCODE_AUTH_KEY_ID when using Xcode API-key signing."
  [[ -n "${XCODE_AUTH_KEY_ISSUER_ID}" ]] || fail "Set XCODE_AUTH_KEY_ISSUER_ID when using Xcode API-key signing."
  [[ -f "${XCODE_AUTH_KEY_PATH}" ]] || fail "Xcode API key file not found: ${XCODE_AUTH_KEY_PATH}"
  XCODE_AUTH_ARGS=(
    -authenticationKeyPath "${XCODE_AUTH_KEY_PATH}"
    -authenticationKeyID "${XCODE_AUTH_KEY_ID}"
    -authenticationKeyIssuerID "${XCODE_AUTH_KEY_ISSUER_ID}"
  )
fi

cd "${ROOT_DIR}"

if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate
fi

rm -rf "${ARCHIVE_PATH}" "${EXPORT_DIR}"
mkdir -p "${ARCHIVE_DIR}" "${EXPORT_DIR}"

ARCHIVE_ARGS=(
  -scheme "${SCHEME}"
  -configuration Release
  -destination "generic/platform=iOS"
  -archivePath "${ARCHIVE_PATH}"
  -allowProvisioningUpdates
)
if [[ "${#XCODE_AUTH_ARGS[@]}" -gt 0 ]]; then
  ARCHIVE_ARGS+=("${XCODE_AUTH_ARGS[@]}")
fi
ARCHIVE_ARGS+=(
  DEVELOPMENT_TEAM="${TEAM_ID}"
  archive
)
xcodebuild "${ARCHIVE_ARGS[@]}"

EXPORT_ARGS=(
  -exportArchive
  -archivePath "${ARCHIVE_PATH}"
  -exportPath "${EXPORT_DIR}"
  -exportOptionsPlist "${EXPORT_OPTIONS}"
  -allowProvisioningUpdates
)
if [[ "${#XCODE_AUTH_ARGS[@]}" -gt 0 ]]; then
  EXPORT_ARGS+=("${XCODE_AUTH_ARGS[@]}")
fi
xcodebuild "${EXPORT_ARGS[@]}"

echo "Uploaded ${SCHEME} archive to App Store Connect/TestFlight."
