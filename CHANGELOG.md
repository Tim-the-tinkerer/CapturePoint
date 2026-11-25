# Changelog

## 0.5.3 — 2026-11-24

- Full-screen and main-display recordings include the menu bar, the Dock, and the desktop.
- The four capture targets stay readable. Titles no longer clip, and More in Settings sits under the grid.
- Quit CapturePoint in the menu bar extra is enabled.
- Quitting during a countdown or a still capture cancels that capture. Quitting during a recording still saves the movie first.
- A display that fails to start recording no longer cancels the other displays. A movie that does not finish is removed.
- A failed on-screen audio tap releases the audio device, and an empty audio file is not left behind.

## 0.5.2 — 2026-11-24

- Full-screen screenshots capture every display, one file each.
- Full-screen recordings save one movie per display. Sound stays in the first movie, on the same clock as its picture.
- Window and selection recordings honor Include pointer and Highlight mouse clicks. Full-screen click highlights need macOS 15.
- The record limit for a window or selection starts when capture starts, not when the picker appears.
- Quitting finishes an in-progress recording before the app exits.
- Recent copy works for JPEG, TIFF, and PDF stills, not only images AppKit can draw.
- Saving over an existing file replaces it in place.
- A failed history write rolls back that list edit, and Clear list can recover a corrupt history file.
- Microphone permission is requested only when Record microphone is on.

## 0.5.1 — 2026-08-16

- Fix A/V sync: a 180s file-watch timeout was treated as audio preroll, so long window recordings skipped minutes of sound. Mux now uses leftover audio duration and ignores impossible clock hints.

## 0.5 — 2026-08-16

- Rename the app to **CapturePoint**.
- Set the marketing version to 0.5.

## 1.6.0 — 2026-08-16

- Reorganize the main window around **Destination**, then **Screenshot / Recording**, then the same four targets.
- Move menu bar, global hotkeys, shutter sound, microphone, and record limit into a Settings window (⌘,).
- Keep Recent lightweight: poster preview, open, reveal, copy, trash.

## 1.5.0 — 2026-08-16

- Tests for capture finalization, filename collisions, history persist/recovery, trash, folder-create failures, audio-mux alignment, and the three permission states.
- Header **Permissions** badge lists Screen Recording, Audio Capture, and Microphone separately.
- Folder creation and Trash failures are reported instead of being treated as success. A corrupt `history.json` is left in place until **Clear list**.
- MIT license, generic README build path, and [DISTRIBUTION.md](DISTRIBUTION.md) for Developer ID signing and notarization.
- Document that the app runs on macOS 13, but on-screen audio needs 14.2+.

## 1.4.6 — 2026-08-16

- Fix Recent **Clear list**: the selected screenshot preview was overflowing its frame and stealing the click, which opened the file instead of clearing the list.

## 1.4.5 — 2026-08-16

- Fix A/V sync: `screencapture` only writes the movie when it stops, so file-watch timing was always 0. Align by audio-duration minus video-duration (tap pre-roll).

## 1.4.4 — 2026-08-16

- Sync on-screen audio with window/selection recordings by skipping tap audio from before the video file actually starts (after you click the window).

## 1.4.3 — 2026-08-16

- Play recordings in the Recent preview with sound (AppKit player). Recent files already contained an audio track; the old preview was a silent still.

## 1.4.2 — 2026-08-16

- Fix global system-audio tap (tap-only aggregate; was silent). Status reports mix/permission failures. Log: `~/Library/Application Support/CapturePoint/audio.log`.

## 1.4.1 — 2026-08-16

- On-screen audio now uses a Core Audio process tap (the system output mix), so browser video sound is captured. Grant **Audio Capture** if macOS asks.

## 1.4.0 — 2026-08-16

- Restore the system window/selection picker (`screencapture`) that captures browsers correctly.
- Window and selection recordings use that picker again; on-screen audio is mixed in from the system audio tap.
- Full-screen recording still uses ScreenCaptureKit for picture + on-screen audio in one pass.

## 1.3.0 — 2026-08-16

- Window capture/record uses a window list instead of click-to-select.
- Browser windows (Chrome, Safari, Edge) are recorded by cropping the display, so the page is visible and on-screen audio is included.

## 1.2.2 — 2026-08-16

- Fix recordings that looked silent or empty: video is written through a pixel-buffer adaptor, and on-screen audio is kept (including samples that arrive before the first video frame). Status line reports whether sound was captured.

## 1.2.1 — 2026-08-16

- Fix browser recordings (Chrome, Safari, Edge): window capture is now a display crop so the page is visible and the video’s soundtrack is included.

## 1.2.0 — 2026-08-16

- Recordings now capture **on-screen audio** (the sound of videos and apps in the capture) via ScreenCaptureKit. This is on by default.
- Microphone remains a separate optional track.
- Selection and window recording use an in-app picker, then record with system audio.

## 1.1.1 — 2026-08-16

- Fix crash on launch when a recording was in Recent. SwiftUI `VideoPlayer` aborts on this macOS; previews now use a poster frame and Play opens the file.

## 1.1.0 — 2026-08-16

- Screen recording for selection, window, full screen, and main display.
- Stop from the on-screen recording bar, menu bar, Record menu, or ⌃⌘. / ⌃⌘R.
- Optional microphone, click highlights, and a time limit.
- Recordings save as `.mov` to the same chosen folder (or ask each time).
- Recent list plays videos and shows a poster frame.

## 1.0.2 — 2026-08-16

- Fix Recent list showing the wrong screenshot. Preview views were reused with stale image state, so clicking one item displayed the other.

## 1.0.1 — 2026-08-16

- Fix screenshots never being written to disk when “Also copy to clipboard” was on (the default). `screencapture -c` is clipboard-only and ignores the file path; CapturePoint now saves the file, then copies it.

## 1.0.0 — 2026-08-16

- First release.
- Choose any save folder, with presets, recents, and drag-and-drop.
- Optional “ask where to save after each capture.”
- Selection, window, full-screen, and main-display capture via `screencapture`.
- Delay countdown, hide-app, clipboard copy, pointer, and shutter sound.
- PNG / JPEG / TIFF / PDF.
- Recent-capture list with preview, reveal, copy, and trash.
- Menu bar extra and optional ⌃⌘3 / ⌃⌘4 / ⌃⌘5 global hotkeys.
