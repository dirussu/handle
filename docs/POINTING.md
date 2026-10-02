# Pointing — how Handle highlights things on screen

The pointing primitive: the user asks *"where is X?"* and the metaball pointer draws a glowing outline around the right on-screen element. This documents the architecture **validated on-device** (Qwen 2.5 VL 7B), because it's the inverse of the obvious approach.

## TL;DR — AX enumerates, the model selects
1. Capture the frontmost screen and enumerate its interactive Accessibility (AX) elements — each with an **exact frame**.
2. Hand the model a **numbered list** of those elements (role + label).
3. The model returns the **index** of the best match — `{"name":"point_at","arguments":{"index":16}}`.
4. Highlight that element's frame (re-read **live** at draw time).

The model does **semantics** (which element matches "back button"?) — its strength. AX provides **geometry** (the exact frame) — its strength. The model never produces coordinates.

## Why not "the model points at x,y"? (the dead end)
The original plan was *"vision points, AX pins"*: the model gives a rough (x,y); a system-wide AX hit-test at that point snaps to the element. **It failed.** The local 7B cannot localize — asked for Finder's toolbar Back button it pointed at the file list, ~3 for 3, wildly wrong. It *names* elements correctly but can't *place* them, and higher image resolution won't fix a 7B's grounding. So we stopped asking the model for coordinates at all.

## Pipeline (code map)
- **Capture + enumerate:** `HandleApp.handleCapture` / `captureCurrentScreen` → `AccessibilityProbe.elements(in:of:limit:)`.
- **Candidate list + prompt:** `HandleApp.pointAtToolInstruction(elements:)` — numbered list + one-shot example. Injected only when `promptAsksToPoint(text)` is true and it's not the initial explain turn.
- **Parse the reply:** `HandleApp.parseToolCall` (+ `jsonObjectCandidates`) — wrapper-agnostic.
- **Dispatch:** `HandleApp.dispatchPointAtIfPresent` — index → `conversation.axElements[idx]` → `AccessibilityProbe.liveFrame` → `MetaballPointer.guide`.

## Hard-won details (each cost a debug cycle)
- **Parse any wrapper.** The 7B wraps the call in a ` ```json ` fence, not Qwen's `<tool_call>` tags. The parser finds the JSON object by scanning balanced braces, ignoring the wrapper.
- **Index may be a string.** `"index":"16"` — coerced via `intArg`.
- **Rank controls first + dedup.** Finder/Settings flood the AX list with duplicate static-text file labels; a low cap then drops the actual buttons. `rankAndDedup` dedups by role+label+position and ranks actionable controls ahead of static text.
- **Re-read the frame LIVE at draw time.** The capture-time frame goes stale if the window reflows during the seconds of inference (System Settings reflows between panes). `AXElement.elementRef` + `AccessibilityProbe.liveFrame`.
- **Coordinate space is identity** (top-left points) on a single main display; validated via ⌘⌥P (highlights the element under the cursor, pixel-perfect). Multi-display would need a screen-origin offset (untested).

## Coverage
- **Native** (Finder, Mail, Notes) **+ System Settings** (focused-window traversal): rich candidates, exact frames. Works.
- **Electron/Chromium** (Claude, Slack, VS Code): **works.** Two things are required: (1) `AXManualAccessibility` set true (primed on activation, `setupAccessibilityPriming`) — turns the tree on; (2) deep traversal — Chromium buries real content ~16–18 levels below the window (AXWindow → ~6×AXGroup → AXWebArea → more groups → buttons), so `elements()` uses `maxDepth 24` (14 cut it all off → only 2–3 coarse candidates). Validated: Claude desktop → 25 real candidates, model points correctly. (`__axtree__` debug command dumps the raw tree.)
- **Custom-drawn** (games, canvas): no AX → no candidates → no pointing (vision-coordinates isn't a usable fallback for the 7B).

## Known-open
- The 7B is **inconsistent** about emitting the tool call (sometimes echoes the prompt with no call). Measure the rate, then add a retry if warranted.
- The `highlight` tool (rect) still takes a model-supplied pixel rect — same localization flaw as the old point_at. When it's wired to the model, it should move to AX-select too.

## Testing without the GUI (DEBUG harness)
The app watches `/tmp/handle_test_cmd`:
- `echo "where is the back button" > /tmp/handle_test_cmd` → runs the full pipeline against the frontmost app; the dispatch logs the chosen element + frame.
- `echo "__selftest__" > /tmp/handle_test_cmd` → pure-logic checks (parser, ranking) log PASS/FAIL — **no model load**, low RAM.

Read results: `log stream --predicate 'subsystem == "com.dimarussu.Handle"' --level info`.
