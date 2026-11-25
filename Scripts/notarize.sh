#!/bin/bash
# Notarize and staple CapturePoint.app. Requires a Developer ID signed bundle.
# See DISTRIBUTION.md.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="CapturePoint.app"
IDENTITY="${SIGN_IDENTITY:-}"
PROFILE="${NOTARY_PROFILE:-}"

if [[ ! -d "${APP}" ]]; then
    echo "error: ${APP} not found. Run ./build-app.sh --no-launch first." >&2
    exit 1
fi

if [[ -z "${IDENTITY}" || "${IDENTITY}" == "-" ]]; then
    echo "error: set SIGN_IDENTITY to a Developer ID Application identity. Ad-hoc builds cannot be notarized." >&2
    exit 1
fi

ZIP="$(mktemp -t CapturePoint-notarize).zip"
ditto -c -k --keepParent "${APP}" "${ZIP}"

if [[ -n "${PROFILE}" ]]; then
    xcrun notarytool submit "${ZIP}" --keychain-profile "${PROFILE}" --wait
elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]]; then
    xcrun notarytool submit "${ZIP}" \
        --apple-id "${APPLE_ID}" \
        --team-id "${APPLE_TEAM_ID}" \
        --password "${APPLE_APP_SPECIFIC_PASSWORD}" \
        --wait
else
    rm -f "${ZIP}"
    echo "error: set NOTARY_PROFILE or APPLE_ID, APPLE_TEAM_ID, and APPLE_APP_SPECIFIC_PASSWORD." >&2
    exit 1
fi

rm -f "${ZIP}"
xcrun stapler staple "${APP}"
xcrun stapler validate "${APP}"
echo "Notarized and stapled ${APP}"
