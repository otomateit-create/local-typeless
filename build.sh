#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-debug}"
APP_NAME="TypelessLocal"
APP_BUNDLE="${APP_NAME}.app"
BINARY_PATH=".build/${CONFIG}/${APP_NAME}"

echo "Building (${CONFIG})..."
if [ "$CONFIG" = "release" ]; then
    swift build -c release
else
    swift build
fi

echo "Packaging ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
cp "${BINARY_PATH}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"

SIGN_IDENTITY="TypelessLocal Dev Signing"
echo "Signing (${SIGN_IDENTITY})..."
codesign --force --deep --sign "${SIGN_IDENTITY}" "${APP_BUNDLE}"

echo "Done: $(pwd)/${APP_BUNDLE}"
