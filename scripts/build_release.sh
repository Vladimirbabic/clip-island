#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHIVE_DIR="${ROOT_DIR}/build/archives"
EXPORT_DIR="${ROOT_DIR}/build/export"

mkdir -p "${ARCHIVE_DIR}" "${EXPORT_DIR}"
cd "${ROOT_DIR}"

if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate
fi

xcodebuild \
  -scheme ClipStory \
  -configuration Release \
  -archivePath "${ARCHIVE_DIR}/ClipStory.xcarchive" \
  archive

echo "macOS archive written to ${ARCHIVE_DIR}/ClipStory.xcarchive"
echo "Next: notarize/export with your Apple Developer credentials."
