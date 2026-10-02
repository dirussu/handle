# Handle Automation Agents — design & implementation plan

> **History note (2026-09-20).** This document is the design record of the recipe and
> automation system as built in 2026-07 for an on-device 4B/7B model. Two things changed
> since: the model is now the user's own provider (`PROVIDERS.md`, 2026-09-19), and
> recipes no longer gate the loop — the agent loop decides and calls `run_recipe` when a
> verified recipe fits (`ASSISTANT.md`, 2026-09-20). Creative and coding jobs ("build a
> website") are in scope now. The recipe library, schedules, triggers and the consent
> model described here are all still live; read the "7B can't plan" passages as the
> history of why recipes exist, not as a limit of the current model.

**Goal:** the user states a *goal*; Handle performs a multi-step automation toward it,
and can **save + schedule** it as a reusable, private recipe on this Mac.

---

## DECISION: recipe-first, not freeform planning (decided on evidence)

We probed whether the local 7B (Qwen 2.5 VL) can plan multi-step automations from
scratch (`__plan__` harness command, 2026-07-01). It cannot, reliably:

| Probe | Result |
|---|---|
| "today's calendar → a prep reminder per meeting" | ✅ **Good** — `read_calendar_events` → `create_reminder` per event, right order |
| "move desktop PDFs into Documents/PDFs" | ⚠️ **Partial** — right shape but **hallucinated a `filter_pdf_files` tool** |
| "quit Mail & Slack, open Downloads, 20-min timer" | ❌ **Poor** — planned `draft_email_reply` "to quit Mail"; never reached for `run_applescript` |

This matches the literature exactly: small (1–7B) models are a sweet spot for
*single-turn tool calls and NL→structured output*, but degrade on *long-horizon,
branching, or ambiguous-tool-selection* planning (the recommended fix — "hand the
planning turn to a frontier model" — is exactly what the 2026-09 provider migration did
for the fallback loop; recipes still carry the happy path).

**Therefore the 7B does NOT plan freely. It RETRIEVES a proven recipe and FILLS its
parameters** — both things it's demonstrably good at (probe ① nailed param-fill).
Freeform planning survives only as a flagged, approval-gated fallback for the long
tail. The recipe library is not polish — **it is the architecture.**

Sources: [LangChain plan-and-execute](https://www.langchain.com/blog/planning-agents),
[SLMs for on-device agents](https://www.digitalapplied.com/blog/small-language-models-on-device-agents-2026-guide),
[macos-automator-mcp](https://github.com/steipete/macos-automator-mcp) (200+ parameterized recipes — the prior art we mine).

---

## What already exists (the foundation — ~70% of the machinery)

| Piece | Where | Reuse for recipes |
|---|---|---|
| Bounded tool loop | `runToolLoop` / `streamOneTurn` | executes a recipe's steps |
| **Select-by-index pattern** | pointing (`AX enumerates → 7B picks index`) | **← this is exactly how the 7B picks a recipe** |
| `run_applescript` (self-healing, `.sdef`) | `ToolRegistry` / `AppleScriptTool` | runs `applescript` recipes |
| Confirm card + preview-diff | `awaitConfirmation` / `confirmRows` | shows the resolved recipe before it runs |
| Audit log | `AuditLog` | records every recipe step |
| Format-agnostic parser | `parseToolCall` | reads the 7B's index / param picks |

The single most important reuse: **recipe selection is the same problem as pointing.**
Pointing worked *because* we stopped asking the 7B to generate (coordinates) and had
it SELECT from an enumerated list by index. Recipe selection is identical — enumerate
candidate recipes, the 7B returns an index. We already know this works on this model.

---

## The recipe architecture

### 1. Recipe format
A recipe is a file (`~/Library/Application Support/Handle/recipes/*.md`, seeded from a
bundled set) — frontmatter + a parameterized body. Two `kind`s:

**`applescript` (primary, v1)** — a parameterized AppleScript. Handles loops, logic,
and app control *natively* (AppleScript's strength), so the 7B only fills params.
Directly minable from macos-automator-mcp.

```markdown
---
id: quit-apps
title: Quit applications
description: Quit one or more running apps.
keywords: [quit, close, exit, app]
kind: applescript
params:
  - { name: apps, type: string[], prompt: "App names to quit, e.g. Mail, Slack" }
confirm: "Quit: ${apps}"
---
repeat with a in ${apps}
    tell application (a as text) to quit
end repeat
```

**`tool-sequence` (v1.5, for high-level tools with nicer cards)** — a short LINEAR
list of Handle tool calls with placeholders (no branching DSL — keep it dumb; anything
needing loops/logic is an `applescript` recipe instead).

```markdown
---
id: prep-reminders-today
title: Prep reminder per meeting today
keywords: [calendar, meeting, reminder, prep]
kind: tool-sequence
params:
  - { name: lead, type: int, default: 30, prompt: "Minutes before to remind" }
steps:
  - { tool: read_calendar_events, args: { range: today }, bind: events }
  - { tool: create_reminder, forEach: events, args: { title: "Prep for ${item.title}" } }
---
```

### 2. Retrieval (the 7B SELECTS, never invents)
1. **Prefilter** (plain code, no model): keyword/substring match the user's goal
   against every recipe's `keywords`+`title`+`description` → top ~8 candidates.
2. **Select** (the pointing pattern): present the candidates as a NUMBERED list to
   the 7B → it returns the best index, or `-1` for "none fit" (the same graceful-
   decline sentinel pointing uses). No free generation → **no hallucinated tools.**

### 3. Parameter fill (the 7B's proven strength)
Given the chosen recipe's `params` (with prompts/types) and the goal, the 7B emits a
JSON object of param values (one `streamOneTurn`, structured output — probe ① showed
it's good at this). Values are **type-validated** before use; a missing required
param → ask the user one question, don't guess.

### 4. Execution + safety
Substitute params → resolve the body → show it on the **confirm card** (`confirm:`
line + the fully-resolved script/steps = preview-diff) → ONE approval → execute
(`applescript` via `run_applescript`; `tool-sequence` via the loop) → every step to
the **audit log**. Self-heal per step (existing retry + `.sdef`).

### 5. Fallback for the long tail (no recipe fits, index = -1)
Two options, decided per build: (a) **graceful decline** — "I don't have a recipe for
that yet" (safe, honest, v1); (b) **constrained freeform** — a single `read →
transform → act` plan, clearly flagged "best-effort", approval-gated. Start with (a);
add (b) once the recipe library covers the common cases.

---

## Phased plan (each independently shippable)

### Phase 0 — Shortcuts tools · ~half day · ships now
`run_shortcut(name)` → `/usr/bin/shortcuts run` (`.confirm`); `list_shortcuts()` →
`shortcuts list` (`.auto`). Pure `ToolRegistry.execute` extension. Immediate reach
into the OS automation layer; also lets recipes *call* Shortcuts.

### Phase 1 — Recipe engine (retrieval → fill → execute)
**✅ Core PROTOTYPED + VALIDATED (2026-07-01)** — `Recipe.swift` (models + resolver +
8 recipes + prefilter) and `matchRecipe`/`fillParams`/`runRecipeProbe` (`__recipe__`
harness). Live results: **6/6 retrieval, 6/6 fill.** Two fill-robustness learnings now
baked into the resolver: the 7B (a) wraps scalars in a 1-element array (`[25]`) → UNWRAP
for scalar params; (b) returns `1` for a true/false enum → `oneOf` COERCES boolean-ish
values. **Remaining for Phase 1 proper:** `RecipeRunner` (substitute → confirm card →
`run_applescript` → audit — reusing the existing pieces), file-loaded recipes
(`*.md`), and a missing-required-param → ask-one-question step. Then expand to
~15–25 hand-verified `applescript` recipes (quit/open apps, move-files-by-type, new
note/doc, play/pause music, focus setups, calendar/reminder chores).

### Phase 2 — Seed the recipe library (mine existing collections)
**Lead source: `raycast/script-commands`** (MIT, ~174 `.applescript` with typed
`@raycast.argumentN {type,placeholder}` headers) — a parser converts those near-
mechanically (`item N of argv` → `${param}`) and covers most of the way to 200 in one
pass. Then adapt `steipete/macos-automator-mcp`'s ~200 KB tips (frontmatter ~1:1;
`${inputData.x}` → `${x}`) and hand-wrap `kevin-funderburg`/`ChristoferK` for gaps.
MIT/CC0 sources only. Curate for *reliability + performance* (PRODUCT.md #17: bounded
queries, no `keystroke` for long text). Full source list + license flags in REPOS.md §1.
This is the moat — a big, curated, local recipe library competitors don't have.

### Phase 3 — Save user automations
After a successful run, "Save as automation" → persist the (recipe id + filled params)
or a captured tool sequence as a named user recipe (`automations.json`, `AutomationStore` actor).

### Phase 4 — Scheduler
In-app `Timer` runs due saved automations under **standing consent** (approved once at
save → no per-step cards; every step still audited; failure → pause + notify). Time-
based recurring first; triggers later. Global "pause all automations" switch.

### Phase 5 — Automations UI
Settings → Automations (list, run-now, edit, enable/disable, delete, run-history from
the audit log). Creation is conversational; a "browse recipes" view surfaces the library.

### Phase 6 — Reactive triggers (the differentiator) · ✅ v1 slice SHIPPED (2026-07-03)
**File-trigger slice validated end-to-end:** `AutomationTrigger{kind,folder,ext}` on
`Automation` (old JSON still decodes) · `TriggerEngine` + `FolderWatcher`
(DispatchSource on the dir fd + snapshot diff, debounced 0.7s, dotfiles ignored —
event-driven, no polling; FSEvents is the upgrade path for recursive/multi-folder) ·
conversational creation ("whenever a pdf lands in downloads…" → `parseFileTrigger`
NL→{folder,ext,task} → recipe match/fill → ONE card → saved) · fires under standing
consent with audit, `${trigger_file}` substitutes the new file's path into the body ·
ext-filter + per-file dedupe verified live (png fired: volume 60→25; txt ignored;
re-add deduped). 12 self-tests (89 total). Harnesses: `__trigtest__`, `__trigparse__`.
**v1.1 (same day): appLaunches + wifiConnects SHIPPED** — NSWorkspace
didLaunch observer (re-launch re-fires via pid dedupe) + CWWiFiClient ssidDidChange
delegate (fires on ssid CHANGE; named-network match needs Location permission to read
the SSID — without it only any-network triggers can match; onboarding = task #16).
One combined NL parse (`parseEventTrigger`) routes all three kinds — the 4B needed a
worked example + "when-X-do-Y" framing before it classified "when I open Zoom" as
appLaunches (0/3 → 6/6 after the prompt fix). Sources start/stop with automations
(zero cost when unused). 101 self-tests. Next trigger: windowMatches (AX).
Move from invoke-driven to *ambient*: fire an automation on a LOCAL EVENT, not just a
clock. This is the one capability a cloud desktop agent structurally can't match locally,
and it's what makes Handle more than "a faster way to run a command." Build one
`TriggerEngine` actor with a `TriggerSource` per event behind a common protocol
(`start()/stop()` → typed `TriggerEvent` into one `AsyncStream`); the engine matches events
to user rules and enters the existing "Do" loop — triggers are just another entry point.
Overwhelmingly event-driven (near-zero idle cost); native API per event in REPOS.md §3.
Generalize `AutomationSchedule` → `AutomationTrigger { time | fileAppears | appLaunches |
wifiConnects | windowMatches | … }`, reusing standing-consent + audit unchanged. Ship
order: file-watcher first (`FSWatcher` over `~/Downloads`/screenshots) → app-launch/
frontmost (`NSWorkspace`) → Wi-Fi/SSID → window-title (AX) → clipboard (the one poller,
gated off on lock/sleep). Stay resident via `SMAppService` (`LaunchAtLogin-Modern`).

---

## Open questions
1. ~~Can the 7B plan freeform multi-step?~~ **Answered: no → recipe-first.**
2. ~~Retrieval quality at scale?~~ **Answered (2026-07-03): holds at 97 recipes —
   13/14 after one keyword fix, clean declines on nonsense (see EVALS.md "Recipe
   retrieval at scale"). Residual risk is within-family disambiguation, which lands
   on the confirm card. Keyword curation must cover PARAPHRASES, not title words.**
3. **Param-fill robustness on dates/paths:** probe ① was good, but the "zero-width
   calendar range" and "~/Desktop vs workspace" bugs say param validation must be strict.
4. **Fallback:** ship graceful-decline only (v1), or add constrained freeform early?

## Explicitly deferred / out of scope
- Creative/coding agents (website-building) — out of scope by focus, not by model: Handle automates the Mac; see PRODUCT.md.
- Creating `.shortcut` files (undocumented) — we *call* Shortcuts, don't author them.
- Branching/looping `tool-sequence` DSL — use `applescript` recipes for logic instead.
- Cross-device/cloud sync of recipes — local file only, on brand.
