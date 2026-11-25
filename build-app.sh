#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

LAUNCH=true
for arg in "$@"; do
    case "${arg}" in
        --no-launch) LAUNCH=false ;;
    esac
done

APP="CapturePoint.app"
BUNDLE_ID="com.capturepoint.app"
VERSION="0.5.3"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [[ ! -f Assets/AppIcon.icns ]]; then
    echo "Generating app icon..."
    swift Scripts/GenerateAppIcon.swift
fi

echo "Building CapturePoint ${VERSION} (release)..."
swift build -c release

BIN=".build/release/CapturePoint"
if [[ ! -x "${BIN}" ]]; then
    echo "error: expected binary not found at ${BIN}" >&2
    exit 1
fi

echo "Running self-test..."
"${BIN}" --self-test

echo "Assembling ${APP}..."
rm -rf "${APP}"
rm -rf SnapPath.app
mkdir -p "${APP}/Contents/MacOS"
mkdir -p "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/CapturePoint"
chmod +x "${APP}/Contents/MacOS/CapturePoint"
cp AppInfo.plist "${APP}/Contents/Info.plist"

if [[ -f Assets/AppIcon.icns ]]; then
    cp Assets/AppIcon.icns "${APP}/Contents/Resources/"
fi

echo "Signing ${APP} with ${SIGN_IDENTITY}..."
xattr -cr "${APP}" 2>/dev/null || true
if [[ "${SIGN_IDENTITY}" == "-" ]]; then
    codesign --force --sign - --identifier "${BUNDLE_ID}" --timestamp=none "${APP}/Contents/MacOS/CapturePoint"
    codesign --force --sign - --identifier "${BUNDLE_ID}" --timestamp=none "${APP}"
else
    codesign --force --options runtime --timestamp --entitlements CapturePoint.entitlements \
        --sign "${SIGN_IDENTITY}" --identifier "${BUNDLE_ID}" "${APP}/Contents/MacOS/CapturePoint"
    codesign --force --options runtime --timestamp --entitlements CapturePoint.entitlements \
        --sign "${SIGN_IDENTITY}" --identifier "${BUNDLE_ID}" "${APP}"
fi

plutil -lint "${APP}/Contents/Info.plist" >/dev/null
codesign --verify --verbose=2 "${APP}" 2>/dev/null || codesign --verify "${APP}"

echo "Done: ${APP} (v${VERSION})"
if [[ "${LAUNCH}" == "true" ]]; then
    pkill -x CapturePoint 2>/dev/null || true
    pkill -x SnapPath 2>/dev/null || true
    sleep 0.2
    echo "Launching..."
    open "${APP}"
fi
