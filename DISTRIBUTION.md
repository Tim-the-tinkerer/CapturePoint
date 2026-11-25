# Distribution

CapturePoint is currently an unsandboxed, ad-hoc signed personal build. That is fine on the Mac that compiled it. A public 1.0 needs a Developer ID identity, notarization, and a place people can download updates.

## What the local build does today

`./build-app.sh` compiles a release binary, runs `--self-test`, copies it into `CapturePoint.app`, and signs with `-` (ad-hoc). Gatekeeper will not trust that bundle on another Mac.

The app is **not sandboxed**. It writes to the folder you choose, uses `screencapture`, ScreenCaptureKit, and (on macOS 14.2+) a Core Audio process tap. Those are all possible in a sandbox later, but they need security-scoped bookmarks and extra entitlements. Do not flip sandbox on without a dedicated pass.

## Signing for other people

1. Enroll in the [Apple Developer Program](https://developer.apple.com/programs/).
2. Create a **Developer ID Application** certificate in the developer portal and install it in the signing keychain.
3. Build with that identity:

```bash
export SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
./build-app.sh --no-launch
```

`build-app.sh` then signs with the hardened runtime and `CapturePoint.entitlements`.

Required TCC prompts (not entitlements) after install:

| Permission        | When                         | Settings pane        |
|-------------------|------------------------------|----------------------|
| Screen Recording  | Every still and recording    | Screen Recording     |
| Audio Capture     | On-screen audio, macOS 14.2+ | Audio Capture        |
| Microphone        | Only if that option is on    | Microphone           |

`CapturePoint.entitlements` only declares microphone input for the hardened runtime. Screen Recording and Audio Capture remain user-granted TCC.

## Notarization

After a Developer ID build:

```bash
export SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export APPLE_ID="you@example.com"
export APPLE_TEAM_ID="TEAMID"
export APPLE_APP_SPECIFIC_PASSWORD="xxxx-xxxx-xxxx-xxxx"
./Scripts/notarize.sh
```

The script submits `CapturePoint.app` with `notarytool`, waits, and staples the ticket. Store the app-specific password in the keychain (`xcrun notarytool store-credentials`) if you do not want it in the environment.

Notarization fails if:

- the signature is ad-hoc
- the hardened runtime is missing
- the bundle identifier or version in `AppInfo.plist` is inconsistent
- the app is already signed with a different identity

## Updates

There is no in-app updater yet. For a public 1.0:

1. Ship numbered GitHub Releases (`CapturePoint-0.5.zip` of the notarized, stapled app).
2. Keep `CHANGELOG.md` as the source of release notes.
3. Add [Sparkle](https://sparkle-project.org) only if you want automatic updates. That is a separate integration: an `appcast.xml`, an EdDSA key, and a hardened-runtime exception for the updater.

Do not distribute the unsigned `.build/release/CapturePoint` binary. Ship the app bundle.

## Versioning

- `CFBundleShortVersionString` is the marketing version (`0.5.3`).
- `CFBundleVersion` is the monotonically increasing build number (currently `4`).
- Bump both in `AppInfo.plist`. Keep the `VERSION` string in `build-app.sh` and the About-panel fallback in `MainEntry.swift` on the same numbers.

## Sandbox later

A sandboxed 1.x would need:

- `com.apple.security.app-sandbox`
- security-scoped bookmarks for the save folder (partially stored already)
- user-selected file entitlements for the save panel
- screen-capture and audio-input entitlements
- a plan for `screencapture` and Core Audio taps inside the sandbox

Until that work is done, keep the app unsandboxed and say so in the README.
