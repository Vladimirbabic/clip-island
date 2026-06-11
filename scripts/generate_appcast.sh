#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHIVES_DIR="${1:-${ROOT_DIR}/build/sparkle}"
APPCAST_PATH="${APPCAST_PATH:-${ROOT_DIR}/docs/appcast.xml}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-com.vladbabic.clipstory}"
RELEASE_TAG="${RELEASE_TAG:-v$(awk -F': ' '/MARKETING_VERSION:/ { gsub(/"/, "", $2); print $2; exit }' "${ROOT_DIR}/project.yml")}"
DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-https://github.com/Vladimirbabic/clip-island/releases/download/${RELEASE_TAG}/}"
PRODUCT_URL="${PRODUCT_URL:-https://github.com/Vladimirbabic/clip-island}"
SPARKLE_ED_KEY_FILE="${SPARKLE_ED_KEY_FILE:-}"

find_sparkle_tool() {
  local name="$1"

  if command -v "${name}" >/dev/null 2>&1; then
    command -v "${name}"
    return
  fi

  find "${HOME}/Library/Developer/Xcode/DerivedData" \
    -path "*/SourcePackages/artifacts/sparkle/Sparkle/bin/${name}" \
    -type f \
    -print \
    -quit
}

GENERATE_APPCAST="$(find_sparkle_tool generate_appcast)"
if [[ -z "${GENERATE_APPCAST}" ]]; then
  echo "Could not find Sparkle generate_appcast. Run xcodebuild -resolvePackageDependencies first." >&2
  exit 1
fi

if [[ ! -d "${ARCHIVES_DIR}" ]]; then
  echo "Archive directory does not exist: ${ARCHIVES_DIR}" >&2
  echo "Put notarized ClipStory ZIP/DMG archives there, then re-run this script." >&2
  exit 1
fi

ARGS=(
  --account "${SPARKLE_ACCOUNT}"
  --download-url-prefix "${DOWNLOAD_URL_PREFIX}"
  --link "${PRODUCT_URL}"
  -o "${APPCAST_PATH}"
)

if [[ -n "${SPARKLE_ED_KEY_FILE}" ]]; then
  ARGS+=(--ed-key-file "${SPARKLE_ED_KEY_FILE}")
fi

"${GENERATE_APPCAST}" "${ARGS[@]}" "${ARCHIVES_DIR}"

echo "Generated ${APPCAST_PATH}"
