#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEAM_ID="${TEAM_ID:-DY4JMWWW5S}"
EXPECTED_SIGNER_NAME="${EXPECTED_SIGNER_NAME:-Vladimir Babic}"
NOTARY_PROFILE="${NOTARY_PROFILE:-clipstory-notary}"
NOTARY_APPLE_ID="${NOTARY_APPLE_ID:-}"
NOTARY_PASSWORD="${NOTARY_PASSWORD:-}"
REPO="${GITHUB_REPOSITORY:-Vladimirbabic/clip-island}"
PUBLISH_GITHUB_RELEASE="${PUBLISH_GITHUB_RELEASE:-1}"
SPARKLE_ED_KEY_FILE="${SPARKLE_ED_KEY_FILE:-}"
XCODE_AUTH_KEY_PATH="${XCODE_AUTH_KEY_PATH:-${ASC_API_KEY_PATH:-}}"
XCODE_AUTH_KEY_ID="${XCODE_AUTH_KEY_ID:-${ASC_API_KEY_ID:-}}"
XCODE_AUTH_KEY_ISSUER_ID="${XCODE_AUTH_KEY_ISSUER_ID:-${ASC_API_KEY_ISSUER_ID:-}}"

VERSION="$(awk -F': ' '/MARKETING_VERSION:/ { gsub(/"/, "", $2); print $2; exit }' "${ROOT_DIR}/project.yml")"
BUILD_NUMBER="$(awk -F': ' '/CURRENT_PROJECT_VERSION:/ { gsub(/"/, "", $2); print $2; exit }' "${ROOT_DIR}/project.yml")"
RELEASE_TAG="${RELEASE_TAG:-v${VERSION}}"

ARCHIVE_DIR="${ROOT_DIR}/build/archives"
ARCHIVE_PATH="${ARCHIVE_DIR}/ClipStory.xcarchive"
EXPORT_DIR="${ROOT_DIR}/build/export"
DIST_DIR="${ROOT_DIR}/build/dist"
NOTARY_DIR="${ROOT_DIR}/build/notary"
SPARKLE_DIR="${ROOT_DIR}/build/sparkle"
EXPORT_OPTIONS="${ROOT_DIR}/scripts/exportOptions.developer-id.plist"
APP_NAME="ClipStory.app"
NOTARY_ZIP="${NOTARY_DIR}/ClipStory-${VERSION}-notary.zip"
FINAL_ZIP="${DIST_DIR}/ClipStory-${VERSION}.zip"
APP_BUNDLE_ID="com.vladbabic.clipstory"

fail() {
  echo "error: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

require_cmd awk
require_cmd codesign
require_cmd ditto
require_cmd git
require_cmd security
require_cmd spctl
require_cmd xcodebuild
require_cmd xcrun
require_cmd zip
require_cmd zipinfo

if [[ "${TEAM_ID}" != "DY4JMWWW5S" ]]; then
  fail "Refusing to release with TEAM_ID=${TEAM_ID}; expected DY4JMWWW5S."
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

if security find-identity -v -p codesigning | grep -F "Developer ID Application:" | grep -vqF "${EXPECTED_SIGNER_NAME}"; then
  echo "warning: Non-${EXPECTED_SIGNER_NAME} Developer ID identities exist locally and will not be accepted for this release." >&2
fi

if ! security find-identity -v -p codesigning | grep -Eq "Developer ID Application: .*${EXPECTED_SIGNER_NAME}.*\\(${TEAM_ID}\\)"; then
  if [[ "${#XCODE_AUTH_ARGS[@]}" -eq 0 ]]; then
    fail "Missing Developer ID Application certificate for ${EXPECTED_SIGNER_NAME} (${TEAM_ID}). Install it in Keychain/Xcode, or provide XCODE_AUTH_KEY_PATH, XCODE_AUTH_KEY_ID, and XCODE_AUTH_KEY_ISSUER_ID so xcodebuild can fetch signing assets."
  fi
  echo "warning: ${EXPECTED_SIGNER_NAME} Developer ID certificate not found locally; relying on Xcode API-key signing." >&2
fi

if [[ "${#XCODE_AUTH_ARGS[@]}" -eq 0 ]]; then
  PROFILE_DIR="${HOME}/Library/MobileDevice/Provisioning Profiles"
  if [[ ! -d "${PROFILE_DIR}" ]] || ! find "${PROFILE_DIR}" -type f \( -name "*.provisionprofile" -o -name "*.mobileprovision" \) -print -quit | grep -q .; then
    echo "warning: No local provisioning profiles found. Developer ID CloudKit export may still fail unless Xcode has an account that can download a profile for ${APP_BUNDLE_ID}." >&2
  fi
fi

if ! xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1 && [[ -z "${NOTARY_APPLE_ID}" ]]; then
  fail "Missing notary profile '${NOTARY_PROFILE}'. Set NOTARY_APPLE_ID to use a secure password prompt, or create the keychain profile."
fi

if ! command -v gh >/dev/null 2>&1 && [[ "${PUBLISH_GITHUB_RELEASE}" == "1" ]]; then
  fail "GitHub CLI is required when PUBLISH_GITHUB_RELEASE=1."
fi

cd "${ROOT_DIR}"

if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate
fi

rm -rf "${ARCHIVE_PATH}" "${EXPORT_DIR}" "${DIST_DIR}" "${NOTARY_DIR}" "${SPARKLE_DIR}"
mkdir -p "${ARCHIVE_DIR}" "${EXPORT_DIR}" "${DIST_DIR}" "${NOTARY_DIR}" "${SPARKLE_DIR}"

xcodebuild \
  -scheme ClipStory \
  -configuration Release \
  -archivePath "${ARCHIVE_PATH}" \
  -allowProvisioningUpdates \
  ${XCODE_AUTH_ARGS+"${XCODE_AUTH_ARGS[@]}"} \
  DEVELOPMENT_TEAM="${TEAM_ID}" \
  archive

xcodebuild \
  -exportArchive \
  -archivePath "${ARCHIVE_PATH}" \
  -exportPath "${EXPORT_DIR}" \
  -exportOptionsPlist "${EXPORT_OPTIONS}" \
  -allowProvisioningUpdates \
  ${XCODE_AUTH_ARGS+"${XCODE_AUTH_ARGS[@]}"}

APP_PATH="${EXPORT_DIR}/${APP_NAME}"
[[ -d "${APP_PATH}" ]] || fail "Exported app not found at ${APP_PATH}."

CODESIGN_INFO="$(codesign -dv --verbose=4 "${APP_PATH}" 2>&1)"
echo "${CODESIGN_INFO}" | grep -q "TeamIdentifier=${TEAM_ID}" || fail "Exported app is not signed by team ${TEAM_ID}."
echo "${CODESIGN_INFO}" | grep -Eq "Authority=Developer ID Application: .*${EXPECTED_SIGNER_NAME}" || fail "Exported app is not signed with Developer ID Application: ${EXPECTED_SIGNER_NAME}."
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

ditto -c -k --keepParent "${APP_PATH}" "${NOTARY_ZIP}"

NOTARY_ARGS=()
if xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1; then
  NOTARY_ARGS=(--keychain-profile "${NOTARY_PROFILE}")
elif [[ -n "${NOTARY_APPLE_ID}" ]]; then
  if [[ -z "${NOTARY_PASSWORD}" ]]; then
    printf "App-specific password for %s: " "${NOTARY_APPLE_ID}" >&2
    IFS= read -rs NOTARY_PASSWORD
    printf "\n" >&2
  fi
  NOTARY_ARGS=(--apple-id "${NOTARY_APPLE_ID}" --team-id "${TEAM_ID}" --password "${NOTARY_PASSWORD}")
else
  fail "Created ${NOTARY_ZIP}, but missing notary profile '${NOTARY_PROFILE}'. Set NOTARY_APPLE_ID to use a secure password prompt, or create the keychain profile."
fi

xcrun notarytool submit "${NOTARY_ZIP}" "${NOTARY_ARGS[@]}" --wait
xcrun stapler staple "${APP_PATH}"
spctl --assess --type execute --verbose "${APP_PATH}"

(
  cd "${EXPORT_DIR}"
  rm -f "${FINAL_ZIP}"
  COPYFILE_DISABLE=1 zip -r -y -q "${FINAL_ZIP}" "${APP_NAME}"
)

if zipinfo -1 "${FINAL_ZIP}" | grep -Eq '(^|/)\._|^__MACOSX'; then
  fail "Release ZIP contains AppleDouble metadata that can invalidate nested framework signatures."
fi

cp "${FINAL_ZIP}" "${SPARKLE_DIR}/"

if [[ -z "${SPARKLE_ED_KEY_FILE}" && -f "${ROOT_DIR}/build/sparkle_private_key.ed25519" ]]; then
  SPARKLE_ED_KEY_FILE="${ROOT_DIR}/build/sparkle_private_key.ed25519"
fi

SPARKLE_ED_KEY_FILE="${SPARKLE_ED_KEY_FILE}" RELEASE_TAG="${RELEASE_TAG}" "${ROOT_DIR}/scripts/generate_appcast.sh" "${SPARKLE_DIR}"

if [[ "${PUBLISH_GITHUB_RELEASE}" == "1" ]]; then
  if gh release view "${RELEASE_TAG}" --repo "${REPO}" >/dev/null 2>&1; then
    gh release upload "${RELEASE_TAG}" "${FINAL_ZIP}" "${ROOT_DIR}/docs/appcast.xml" --repo "${REPO}" --clobber
  else
    gh release create "${RELEASE_TAG}" "${FINAL_ZIP}" "${ROOT_DIR}/docs/appcast.xml" \
      --repo "${REPO}" \
      --target "$(git rev-parse HEAD)" \
      --title "ClipStory ${VERSION}" \
      --notes "ClipStory ${VERSION} (${BUILD_NUMBER})"
  fi
fi

echo "Release ZIP: ${FINAL_ZIP}"
echo "Sparkle appcast: ${ROOT_DIR}/docs/appcast.xml"
