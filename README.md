# Stick

A small native Mac menu bar app for leaving private notes on selected text in other apps.

Select text → **Control–Option–N** by default → write a note → **Escape** to return to work.
Press **Control–Option–P** by default to toggle pins in the current document. Click a pin to edit its note.

Change either shortcut in **Stick → Settings…** from the menu bar, or press **Command–comma** while a Stick window is active. Choose modifiers and a key for each action, then **Apply**. Your choices persist between launches and update the menus and onboarding guide. **Restore defaults** stages the original shortcuts; Apply confirms them.

Stick warns about duplicate assignments, its own menu shortcuts, enabled macOS system shortcuts, and registration conflicts reported by macOS. A rejected change leaves the previous working shortcuts active. Some shortcuts handled inside other apps or shared through other mechanisms cannot be detected; choose another combination if one still overlaps.

## Run

Requires macOS 13 or later and a Swift 5.9+ toolchain. Full Xcode is recommended to run the tests.

```sh
bash scripts/build-app.sh
open dist/Stick.app
```

Keep the app in one location. Stick’s setup window explains its Accessibility access before you enable it. Choose **Enable Accessibility…**, then turn on Stick in System Settings. If macOS doesn’t display a prompt, **Open System Settings** takes you directly to the permission list. The window detects access automatically and shows the note shortcuts. **Start using Stick** returns you to your previous app when it’s still available, or opens your notes.

You can view saved notes without granting access. Setup only completes once permission is confirmed; closing the window doesn’t mark it complete. If access is later removed, Stick hides its pins and guides you through setup the next time you use them. **Need help with access?** explains how to add the app or refresh an outdated entry. Permission changes and expanded help use a brief transition; macOS Reduce Motion disables it.

These development builds are ad-hoc signed, so rebuilding can require removing and re-adding the app’s permission, then relaunching. The onboarding UI cannot eliminate that signing limitation.

Stick’s simple folded-note mark appears in its app icon and menu bar. The menu provides Add Note, Show/Hide Pins, All Notes, Getting Started, and Settings. The app needs no account or network connection. It does not capture screenshots or use the clipboard to read selections.

## Notes and attachment

- Plain-text notes autosave locally to `~/Library/Application Support/Stick/notes.json`. Typing is coalesced into a save after a 180 ms pause; closing a note or quitting flushes pending edits immediately. The editor reports save failures and keeps unsaved text open for retry.
- Each note stores the source app, document URL where available, selected text, and a short surrounding excerpt.
- Exact text and its saved surrounding excerpt establish the attachment. While Stick is tracking the document, verified edits before or after a passage can update its location and surrounding excerpt. Edits inside a passage, ambiguous changes, and changes made while Stick was not observing it can require manual reattachment; a unique remaining quote alone is not enough to move a pin.
- Visible pins respond to Accessibility notifications and scrolling or window dragging, with throttled updates and a 750 ms fallback for apps that do not send useful events. Accessibility calls run away from the main UI thread and have bounded scan time. Unchanged pin windows are left alone.
- Pins align with the first line of their passage. Collisions spread horizontally on that same line; they never wrap onto another line. Pins that cannot fit on the visible screen are hidden until there is room.
- All Notes supports immediate search, opening the source document, editing, deleting, and reattaching a note. Return opens the selected search result (or the first result); Down moves from search into the list. Hidden lists defer redraws, and updates preserve the selected note. Open Source opens the document; it does not automatically scroll to an offscreen passage.
- The Needs location filter reflects missing or ambiguous anchors found when the source document is inspected. Offscreen notes stay in All Notes. Documents that haven't been inspected aren't classified as missing.
- Reattach keeps the note body: choose Reattach, select a new passage in the source app, then use your Add Note shortcut.

## Compatibility

Uses macOS Accessibility only; no editor or browser plugins. Initial diagnostic checks on this development Mac found usable text and scrolling geometry in TextEdit 1.21, Safari 27.2 (ordinary HTML), and VS Code 1.147.0 with Screen Reader Optimized mode active.

TextEdit exposes conventional text ranges. Safari exposes selections through native text markers; v1 supports selections within one text element. VS Code may expose usable geometry on a child text node even when the editor itself returns empty bounds. Native editor scans stay inside the focused text editor, and VS Code's editor label must match the active file; focusing another panel hides pins. Stick does not change accessibility settings in other apps.

This is an early local build. Large documents, virtualized content, code folding, wrapped code, complex web editors, and text split across multiple elements may be unsupported. Live edit tracking is conservative and depends on Stick seeing consecutive document states. It cannot reliably infer edits made while the app was closed, pins were hidden, or the document was not being observed. Edits inside a quote can need reattachment. If an app exposes no stable document URL, Stick falls back to its window title, which is less durable. No claim of universal app compatibility is made.

## Development

```sh
swift test --build-system native
bash scripts/build-app.sh
```

If Xcode is installed but the Command Line Tools are selected, prefix commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` and use `xcrun swift`.

`StickCore` contains the UTF-16-aware anchor matcher, conservative live edit tracker, and atomic, versioned note store. `Stick` contains the accessibility adapter, AppKit windows, global shortcuts, and coordinator.

Read-only integration diagnostic, after selecting sample text in a running target app:

```sh
dist/Stick.app/Contents/MacOS/Stick --check-selection TARGET_PID
```

This invokes the same selection capture and resolution logic as the UI without saving a note. Accessibility permission is still required.

Tests cover shifted text, live nearby edits, Unicode ranges, duplicate and missing anchors, same-line pin layout, debounced saves, search selection, permission states, persistence, deletion, unsupported storage versions, and failed writes. For manual validation, add separate notes to two visible passages, scroll, insert text above them, switch documents, quit/reopen Stick, and test reattachment after deleting the selected passage.

The [live workflow record](docs/live-validation.md) includes TextEdit hotkeys, two independent pins, nearby edits, autosave, keyboard focus, and restart persistence. It distinguishes the running build checks from final changes covered by automated tests.

### Regenerate the app icon

`StickBrand` draws the folded-note artwork locally. From the repository root:

```sh
swiftc Sources/Stick/StickBrand.swift scripts/generate-icon.swift -o /tmp/stick-generate-icon
STICK_ICON_TMP="$(mktemp -d)"
/tmp/stick-generate-icon "$STICK_ICON_TMP/Stick.iconset"
iconutil -c icns "$STICK_ICON_TMP/Stick.iconset" -o Resources/Stick.icns
rm -rf "$STICK_ICON_TMP"
```

Rebuild the app bundle after regenerating `Resources/Stick.icns`.

Distribution builds produced by the script are locally ad-hoc signed. Public distribution requires Developer ID signing and notarization.
