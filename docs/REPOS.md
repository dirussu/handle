# External repos & models — vetted candidates

Research pass 2026-07-02 (four parallel web sweeps). Everything here is filtered for
Handle's hard constraints: **local-only** (no cloud/external-server runtime deps),
**Swift/macOS-native**, and **permissive license** (MIT/Apache/BSD/CC0 — GPL and
unlicensed flagged, not adopted). "Adopt" = link/vendor into the app. "Reference" =
read the code/technique, don't depend on it (license or architecture reasons).

---

## 1. Recipe sources to MINE (grow the library 8 → 200+)

The recipe library is the moat. Convert these into Handle `.md` recipe files (frontmatter +
`${param}` AppleScript body). Only MIT/CC0 sources.

| Repo | License | Status | Yield | Translation effort |
|---|---|---|---|---|
| **`raycast/script-commands`** ⭐ | MIT | active (2026-04) | ~174 `.applescript` (+600 shell) | **Near-mechanical** — files already carry `@raycast.argumentN {type,placeholder}` typed headers + `on run argv`; a parser maps title→title, argumentN→typed params, `item N of argv`→`${param}`. One repo → 100+ recipes. |
| `steipete/macos-automator-mcp` (the `knowledge_base/`) | MIT | very active | ~200 tips, 13 categories | **Near-zero** — markdown+YAML frontmatter, AppleScript/JXA in fences; ~1:1 with our schema. Use its folder/frontmatter layout as our canonical target format. |
| `kevin-funderburg/AppleScripts` | MIT | stale-but-stable (2021) | ~69 scripts | Moderate — raw `.applescript`, hand-promote hard-coded values to `${params}`. Good Finder/Safari/Mail/Chrome coverage. |
| `ChristoferK/AppleScriptive` | MIT | stale (2019) | ~36 scripts | Moderate — clean idiomatic AppleScript; filename encodes app+action. |
| `extracts/mac-scripting` | MIT | maintained (2026-01) | ~7 | Moderate, niche (DEVONthink/Bookends/Papers) — only if those apps matter. |

**Idea backlogs (not minable code):** `sindresorhus/Actions` (Shortcuts, ~3k★, license undeclared — flag), `vhuty/awesome-shortcuts` (CC0 index). Use to prioritize what to author.
**Skip (license):** `unforswearing/applescript` (NOASSERTION), `briangonzalez/awesome-applescripts` & `abbeycode/AppleScripts` (no license), Shortcuts `.shortcut` binary galleries (not minable). `peakmojo/`·`joshrutkowski/applescript-mcp` (MIT but only ~a dozen hardcoded handlers each — low incremental value over steipete).

**Strategy:** lead with a `raycast/script-commands` parser (one pass → most of the way to 200), copy steipete's frontmatter schema as the target, hand-wrap kevin-funderburg/ChristoferK for gaps. Curate for *performance* (PRODUCT.md #17: bounded queries, no `keystroke` for long text).

---

## 2. Accessibility / UI layer (the "See" targeting engine)

Handle currently hand-rolls `AXUIElement` tree-walking + ranking. This can be replaced.

- **ADOPT — `openclaw/AXorcist`** (MIT, ~299★, pushed *today*, macOS 14+). Swift AX wrapper with chainable fuzzy-matched queries, **hit-testing (element-at-point)**, match strategies (exact/contains/regex/prefix), AXPress/AXSetValue, and **live AX notifications**. Maps directly onto our enumerate → select-by-index flow and the "re-read the element's LIVE frame at draw time" requirement. Replaces the tree-walk *and* most of the criteria/ranking code. 100% local, no network.
- **FALLBACK — `tmandry/AXSwift`** (MIT, ~412★, stable/low-churn). The boring, battle-tested thin wrapper if AXorcist feels too new. Lower-level; you'd keep your own ranking layer.
- **REFERENCE (technique only, don't vendor):**
  - **`trycua/cua`** (MIT, 19k★) — its macOS driver clicks/types **without stealing cursor or focus** via SkyLight `SLEventPostToPid` + yabai focus-without-raise. *Critical for a notch assistant* — see `blog/inside-macos-window-internals.md`. (Framework itself is cloud-adjacent — do NOT adopt.)
  - **`mediar-ai/mcp-server-macos-use`** (NOASSERTION license → read only) — compact `[role] "label" x/y/w/h visible` serialization + returning only the element *diff* after each action (VLM-prompt token savings).
  - **`MacPaw/Screen2AX`** + **`macapptree`** (MIT) — vision-based AX-tree reconstruction; the fallback plan for apps with broken/empty AX (Electron, custom canvases).
  - **`macOS26/Agent`** (MIT, ~515★) — full native-Swift AX-driving agent to read for tool-loop structure.

**Verdict:** adopt AXorcist; borrow Cua's focus-preserving click and macos-use's compact serialization by reading, not depending.

---

## 3. Event/trigger sources (the proactive layer — see AUTOMATIONS.md Phase 6)

Almost every trigger is a **native, event-driven, ~zero-idle-cost API** — depend on the OS, not GitHub packages. Only the clipboard is inherently a poll.

| Event | Canonical native API (use directly) |
|---|---|
| File/screenshot in a folder | **FSEvents** (CoreServices) — kernel-backed, recursive, coalesced |
| App launch/quit/frontmost | **NSWorkspace.notificationCenter** (`didLaunch/didActivate…`) |
| Wi-Fi/network/SSID | **NWPathMonitor** (connectivity) + **CoreWLAN** `ssidDidChange` (needs Location perm) |
| Window title/focus | **AXObserver** (`kAXFocusedWindowChanged/kAXTitleChanged`) — needs AX perm (already held) |
| Clipboard | **NSPasteboard.changeCount** — *no native event; poll ~0.5–1s* (gate off on lock/sleep) |
| Calendar "soon" | **EventKit** `.EKEventStoreChanged` + query + self-scheduled timers |
| Sleep/wake/lock/power | **NSWorkspace** sleep/wake, **DistributedNotificationCenter** `com.apple.screenIsLocked`, **IOKit** power |
| Stay resident / periodic | **SMAppService** (login item, macOS 13+); process stays running → `DispatchSourceTimer`. **`BGTaskScheduler` does NOT apply on macOS.** |

**Helper libs worth adopting (few):**
- **`sindresorhus/LaunchAtLogin-Modern`** (MIT, ~575★) — one-liner `SMAppService` wrapper + SwiftUI toggle. (Old `LaunchAtLogin` is archived → use `-Modern`.)
- **`okooo5km/FSWatcher`** (MIT, ~69★, maintained 2026) — modern folder watcher, FSEvents/DispatchSource backends, depth/exclude filters. Best-maintained option for the file trigger.
- **`p0deje/Maccy` → `Clipboard.swift`** (MIT, 20k★) — reference for the `changeCount` poll (copy the pattern, not a dep).
- `tmandry/AXSwift` — reuse for window-title/focus observers (same dep as §2).

**Architecture:** one `TriggerEngine` actor owning a `TriggerSource` per event type behind a common protocol (`start()/stop()` → typed `TriggerEvent` into one `AsyncStream`); the engine matches events to user rules and hands the automation to the existing "Do" loop. Overwhelmingly event-driven; isolate the clipboard poller and gate it off on `willSleep`/`screenIsLocked`. Near-zero CPU/battery at idle on a 16 GB Air.

---

## 4. Model & notch UI

**KEY INSIGHT:** mlx-swift loads a fixed set of VLM *architectures* (Qwen2-VL, Qwen2.5-VL, Qwen3-VL dense, Idefics3, SmolVLM). The best open UI-grounding models are **fine-tunes of Qwen2.5/Qwen3-VL**, so they **drop into Handle's existing loader with no engine change** — just point at different weights (+ make a 4-bit MLX quant).

| Model | Arch → loadable? | Grounding | License | Fit |
|---|---|---|---|---|
| **Holo2-4B** (Hcompany) ⭐ | Qwen3-VL-4B → **yes** | SS-Pro ~57% | Apache-2.0 | Same size/arch as current, purpose-built grounder → **eval against Qwen3-VL 4B.** Needs a 4-bit MLX quant; "Thinking" variant (reasoning-token latency). |
| Holo1.5-7B | Qwen2.5-VL-7B → yes | SS-Pro ~58% | Apache-2.0 | Pure grounder, no thinking overhead. Fallback if Holo2's thinking hurts; heavier RAM. |
| MAI-UI-8B | GUI foundation → **MLX-4bit quant exists** | n/a on card | Apache-2.0 | Rare ready-made MLX build; smoke-test loadability before trusting. |
| Moondream 3 | MoE → **NO** | high (own metric) | Business Source | Custom MoE — needs its own runtime, not `VLMModelFactory`. Not loadable. |
| Florence-2 / Gemma 3 vision | custom / partial → **NO / flaky** | — | MIT / Gemma | Florence-2 isn't an MLXVLM arch; Gemma 3 vision path is half-wired. Skip. |

**Frameworks:** `ml-explore/mlx-swift-lm` (MIT, very active — the actual VLM engine; watch its arch-support list); `Blaizzy/mlx-vlm` (Python — makes the HF quants; supports more archs than Swift, a bellwether).

**Notch UI:** **ADOPT `MrKai77/DynamicNotchKit`** (MIT, ~430★, active) — the only real reusable SwiftUI *library* for the notch (`DynamicNotch`, `DynamicNotchInfo/Progress`, safe-area handling, works on non-notch Macs). `TheBoredTeam/boring.notch` is GPL-3.0 → reference for polish only, don't link.
