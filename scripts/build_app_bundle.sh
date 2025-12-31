#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1
  pwd
)"

PRODUCT_NAME="ProjectEcho"
APP_BUNDLE_PATH="${ROOT_DIR}/projectecho.app"

INFO_PLIST_SRC="${ROOT_DIR}/Info.plist"
ENTITLEMENTS="${ROOT_DIR}/ProjectEcho.entitlements"

# Keep SwiftPM + Clang caches inside the repo so builds work in restricted/sandboxed environments.
CACHE_ROOT="${ROOT_DIR}/.home"
MODULE_CACHE="${CACHE_ROOT}/.cache/clang/ModuleCache"
SWIFTPM_CACHE="${CACHE_ROOT}/swiftpm-cache"
SWIFTPM_CONFIG="${CACHE_ROOT}/swiftpm-config"
SWIFTPM_SECURITY="${CACHE_ROOT}/swiftpm-security"

mkdir -p "${MODULE_CACHE}" "${SWIFTPM_CACHE}" "${SWIFTPM_CONFIG}" "${SWIFTPM_SECURITY}"

export CLANG_MODULE_CACHE_PATH="${MODULE_CACHE}"

SWIFT_BUILD_COMMON=(
  build
  -c release
  --disable-sandbox
  --manifest-cache local
  --cache-path "${SWIFTPM_CACHE}"
  --config-path "${SWIFTPM_CONFIG}"
  --security-path "${SWIFTPM_SECURITY}"
)

if [[ -f "${ROOT_DIR}/Package.resolved" ]]; then
  SWIFT_BUILD_COMMON+=(--only-use-versions-from-resolved-file)
fi

echo "🎙️ Building Project Echo app bundle…"
echo ""

echo "🔨 Building arm64…"
swift "${SWIFT_BUILD_COMMON[@]}" --triple arm64-apple-macosx14.0

echo "🔨 Building x86_64…"
swift "${SWIFT_BUILD_COMMON[@]}" --triple x86_64-apple-macosx14.0

ARM_BIN="${ROOT_DIR}/.build/arm64-apple-macosx/release/${PRODUCT_NAME}"
X86_BIN="${ROOT_DIR}/.build/x86_64-apple-macosx/release/${PRODUCT_NAME}"

UNIVERSAL_BIN="${ROOT_DIR}/.build/${PRODUCT_NAME}-universal"
lipo -create "${ARM_BIN}" "${X86_BIN}" -output "${UNIVERSAL_BIN}"

echo "📦 Assembling ${APP_BUNDLE_PATH}…"
mkdir -p "${APP_BUNDLE_PATH}/Contents/MacOS" "${APP_BUNDLE_PATH}/Contents/Resources"

cp "${UNIVERSAL_BIN}" "${APP_BUNDLE_PATH}/Contents/MacOS/${PRODUCT_NAME}"
chmod +x "${APP_BUNDLE_PATH}/Contents/MacOS/${PRODUCT_NAME}"

sed 's/\$(DEVELOPMENT_LANGUAGE)/en/g; s/\$(EXECUTABLE_NAME)/ProjectEcho/g' \
  "${INFO_PLIST_SRC}" > "${APP_BUNDLE_PATH}/Contents/Info.plist"
plutil -lint "${APP_BUNDLE_PATH}/Contents/Info.plist" >/dev/null

# Copy any SwiftPM resource bundles (e.g. swift-transformers tokenizers).
shopt -s nullglob
for bundle in "${ROOT_DIR}/.build/arm64-apple-macosx/release"/*.bundle; do
  rm -rf "${APP_BUNDLE_PATH}/Contents/Resources/$(basename "${bundle}")"
  cp -R "${bundle}" "${APP_BUNDLE_PATH}/Contents/Resources/"
done
shopt -u nullglob

echo "🔏 Codesigning…"
codesign --force --deep --sign - --entitlements "${ENTITLEMENTS}" "${APP_BUNDLE_PATH}"
codesign --verify --deep --strict -vv "${APP_BUNDLE_PATH}" >/dev/null

echo ""
echo "✅ Built: ${APP_BUNDLE_PATH}"
echo "🚀 Launch: open \"${APP_BUNDLE_PATH}\""
