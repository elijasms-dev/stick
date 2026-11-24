# Live macOS validation

Validated on 24 November 2026 using a saved TextEdit document with distinct anchors at lines 40 and 60. A temporary, user-approved Swift harness sent system-wide keyboard and mouse events and read Accessibility and WindowServer state. This exercised the running app rather than calling its command handlers directly.

| Check | Result |
| --- | --- |
| Control–Option–N at each passage | Created two separate note IDs with the correct selected quotes |
| Enter different note text | Both bodies autosaved independently |
| Control–Option–P | Revealed and hid both pins |
| Both passages visible | Two distinct 26 × 26 pin windows, vertically aligned with their respective text |
| Click each pin | Reopened the correct body and anchor; note editor received keyboard focus |
| Escape | Closed the editor and returned focus to TextEdit |
| Restart Stick | Both IDs, bodies and anchors survived; both pins could be revealed and reopened |
| Core suite | 13 tests passed |

The test found and fixed a focus-restoration issue: an editor previously returned to the most recently active external app. It now retains its own source application's process ID.

To repeat manually, save a plain-text document containing two distinct passages approximately 20 lines apart. Select each passage and use Control–Option–N to save different notes. Scroll until both passages are visible, reveal the pins with Control–Option–P, and open each pin to check its note. Repeat after quitting and reopening Stick.

This result covers the TextEdit workflow on the development Mac. Safari and VS Code have separate Accessibility diagnostics described in the README; this run does not establish complete workflows in those apps or universal compatibility.
