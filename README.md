# Stick

A small native Mac menu bar app for leaving private notes on selected text in other apps.

Select text → **Control–Option–N** → write a note → **Escape** to return to work.
Press **Control–Option–P** to toggle pins in the current document. Click a pin to edit its note.

## Run

Requires macOS 13 or later and a Swift 5.9+ toolchain. Full Xcode is recommended to run the tests.

```sh
bash scripts/build-app.sh
open dist/Stick.app
```

Keep the app in one location. Stick’s setup window explains its Accessibility access before you enable it. Choose **Enable Accessibility…**, then turn on Stick in System Settings. If macOS doesn’t display a prompt, **Open System Settings** takes you directly to the permission list. The window detects access automatically and shows the note shortcuts. **Start using Stick** returns you to your previous app when it’s still available, or opens your notes.

You can view saved notes without granting access. Setup only completes once permission is confirmed; closing the window doesn’t mark it complete. If access is later removed, Stick hides its pins and guides you through setup the next time you use them. **Need help with access?** explains how to add the app or refresh an outdated entry.

These development builds are ad-hoc signed, so rebuilding can require removing and re-adding the app’s permission, then relaunching. The onboarding UI cannot eliminate that signing limitation.

The menu bar pin provides Add Note, Show/Hide Pins, All Notes, and Getting Started. The app needs no account or network connection. It does not capture screenshots or use the clipboard to read selections.

## Notes and attachment

- Plain-text notes autosave locally to `~/Library/Application Support/Stick/notes.json`.
- Each note stores the source app, document URL where available, selected text, and a short surrounding excerpt.
- Exact text and its saved surrounding excerpt are matched again after scrolling or edits, even when only one copy of the selected text remains. Missing context or ambiguous targets are not pinned; nearby edits can require manual reattachment.
- Visible pins refresh every half second while enabled. Accessibility calls run away from the main UI thread and have bounded scan time.
- All Notes supports search, opening the source document, editing, deleting, and reattaching a note. Open Source opens the document; it does not automatically scroll to an offscreen passage.
- The Unplaced filter reflects missing or ambiguous anchors found when the source document is inspected. Offscreen notes stay in All Notes. Documents that haven't been inspected aren't classified as missing.
- Reattach keeps the note body: choose Reattach, select a new passage in the source app, then press Control–Option–N.

## Compatibility

Uses macOS Accessibility only; no editor or browser plugins. Initial diagnostic checks on this development Mac found usable text and scrolling geometry in TextEdit 1.21, Safari 27.2 (ordinary HTML), and VS Code 1.147.0 with Screen Reader Optimized mode active.

TextEdit exposes conventional text ranges. Safari exposes selections through native text markers; v1 supports selections within one text element. VS Code may expose usable geometry on a child text node even when the editor itself returns empty bounds. Native editor scans stay inside the focused text editor, and VS Code's editor label must match the active file; focusing another panel hides pins. Stick does not change accessibility settings in other apps.

This is an early local build. Large documents, virtualized content, code folding, wrapped code, complex web editors, and text split across multiple elements may be unsupported. The saved quote and its surrounding excerpt must still match; edits inside or near the quote can need reattachment. If an app exposes no stable document URL, Stick falls back to its window title, which is less durable. No claim of universal app compatibility is made.

## Development

```sh
swift test --build-system native
bash scripts/build-app.sh
```

If Xcode is installed but the Command Line Tools are selected, prefix commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` and use `xcrun swift`.

`StickCore` contains the UTF-16-aware anchor matcher and atomic, versioned note store. `Stick` contains the accessibility adapter, AppKit windows, global shortcuts, and coordinator.

Read-only integration diagnostic, after selecting sample text in a running target app:

```sh
dist/Stick.app/Contents/MacOS/Stick --check-selection TARGET_PID
```

This invokes the same selection capture and resolution logic as the UI without saving a note. Accessibility permission is still required.

Tests cover shifted text, Unicode ranges, duplicate anchors, missing text, persistence, deletion, unsupported storage versions, and failed writes. For manual validation, add separate notes to two visible passages, scroll, insert text above them, switch documents, quit/reopen Stick, and test reattachment after deleting the selected passage.

The global shortcuts and two independent TextEdit pins have also passed a [live workflow check](docs/live-validation.md), including clicking both pins, keyboard focus, autosave, and restart persistence.

Distribution builds produced by the script are locally ad-hoc signed. Public distribution requires Developer ID signing and notarization.
