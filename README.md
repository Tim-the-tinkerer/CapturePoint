# CapturePoint

**Version 0.5.3** — a native macOS screenshot and screen-recording app that lets you choose exactly where files are saved.

See [CHANGELOG.md](CHANGELOG.md) for release notes and [DISTRIBUTION.md](DISTRIBUTION.md) for signing and notarization.

## What it does

macOS always dumps screenshots on the Desktop unless you hunt through Screenshot.app settings. **CapturePoint** makes the destination the first thing you set:

- **Choose any folder** (⌘⇧O), or drop a folder onto the window
- **Presets** for Desktop, Pictures/Screenshots, Pictures, Downloads, and Documents
- **Recent folders** for places you have used before
- **Ask each time** — after a capture, a save dialog opens so you can pick a folder and filename
- **Save automatically** to the chosen folder with a unique `Screenshot YYYY-MM-DD at HH.mm.ss` name

Captures use the system `screencapture` tool, so selection and window picking feel like the built-in screenshot UI.

## Features

- **Screenshot** or **Recording**, then the same four targets (selection, window, full screen, main display)
- Full screen captures every display, one file each. A full-screen recording saves one movie per display, and the sound is in the first movie
- Recordings save as `.mov`
- Stop a recording from the red bar, the menu bar extra, **Record → Stop**, or **⌃⌘.**
- **On-screen audio** in recordings (the sound of videos and apps being captured; on by default)
- Optional microphone as a second track
- Optional record limit (15s / 30s / 1 min / 5 min) or until you stop
- Optional countdown delay (3 / 5 / 10 seconds)
- Hide CapturePoint so it does not appear in the shot
- Copy stills to the clipboard; copy recording files
- Include the pointer, shutter sound on or off
- PNG, JPEG, TIFF, or PDF for stills
- Recent list with a light preview, reveal, copy, and trash
- Settings (⌘,) for menu bar, hotkeys, shutter sound, microphone, highlight clicks, and record limit
- Menu bar extra for one-click capture, record, and Quit
- Optional global hotkeys that do **not** replace the system ones:
  - **⌃⌘4** selection still
  - **⌃⌘5** window still
  - **⌃⌘3** full screen still
  - **⌃⌘R** start or stop a full-screen recording

## Requirements

- **macOS 13 Ventura** or later to run stills, recordings, and the UI (`Package.swift` declares this minimum)
- **macOS 14.2 Sonoma** or later for **on-screen audio**. That feature uses `CATapDescription` / `AudioHardwareCreateProcessTap`, which do not exist on 13–14.1. On those versions, recordings are picture-only unless you turn on the microphone
- Xcode / Swift 5.9+ toolchain (to build)

CapturePoint asks for three separate permissions. A Screen Recording grant does **not** cover audio:

| Permission | Needed for | Settings pane |
|---|---|---|
| **Screen Recording** | Every screenshot and recording | Privacy & Security → Screen Recording |
| **Audio Capture** | On-screen audio of videos and apps (macOS 14.2+) | Privacy & Security → Audio Capture |
| **Microphone** | Only if **Record microphone** is on | Privacy & Security → Microphone |

The header **Permissions** badge lists each one.

## Build & run

From the repository root:

```bash
chmod +x build-app.sh
./build-app.sh
```

This builds a release binary, runs `--self-test`, packages `CapturePoint.app`, ad-hoc signs it, and launches it. Ad-hoc signatures are only trusted on the Mac that signed them. See [DISTRIBUTION.md](DISTRIBUTION.md) for Developer ID signing and notarization.

Build without launching:

```bash
./build-app.sh --no-launch
```

Or run the binary directly during development:

```bash
swift run
```

Regenerate the app icon:

```bash
swift Scripts/GenerateAppIcon.swift
```

## Tests

```bash
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
swift test
```

Unit tests cover filename uniqueness and collisions, tilde-path display, capture finalization (empty / tiny / keepable files), history persist / corrupt recovery / trash, folder-create and replace failures, audio-mux lead alignment, and the permission policy that splits Screen Recording, Audio Capture, and Microphone. `./build-app.sh` also runs `--self-test` as a smoke subset.

## Usage

1. Open **CapturePoint**.
2. Set the **Destination** folder (Choose…, a preset, or drop a folder).
3. Pick **Screenshot** or **Recording**, then a target.
4. Use **Details** for format, delay, pointer, and on-screen audio. Persistent options live in **Settings** (⌘,).
5. Grant Screen Recording, Audio Capture, or Microphone from **Permissions** if macOS asks.
6. For a recording, click **Stop** on the red bar when you are done.
7. Recent is a light preview with Open, Reveal, Copy, and Trash.

You can also capture from the camera icon in the menu bar.

## Notes

- The first capture may show the system Screen Recording prompt. Enable CapturePoint in **System Settings → Privacy & Security → Screen Recording** if captures come out blank.
- On-screen audio is a different permission. If a recording is picture-only on macOS 14.2+, grant **Audio Capture**.
- Global hotkeys are off by default so they never collide with ⌘⇧3 / ⌘⇧4 / ⌘⇧5.
- History is a local list under `~/Library/Application Support/CapturePoint/history.json`. Clearing the list does not delete files; **Trash** does.
- CapturePoint is not sandboxed. The chosen folder path is also stored as a bookmark so it survives moves when possible.
- Folder creation and Trash failures are reported in the status line instead of being treated as success.

## Project layout

```
CapturePoint/
  Package.swift
  AppInfo.plist
  CapturePoint.entitlements
  LICENSE
  .gitignore
  build-app.sh
  CHANGELOG.md
  DISTRIBUTION.md
  Assets/
  Scripts/GenerateAppIcon.swift
  Scripts/notarize.sh
  Sources/CapturePointCore/     # filenames, history, mux alignment, permissions
  Sources/CapturePoint/         # app, capture, UI
  Tests/CapturePointCoreTests/
```

## License

[MIT](LICENSE).
