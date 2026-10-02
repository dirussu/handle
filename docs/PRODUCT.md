# Handle — Product Spec v1

_North-star document. Every future product decision answers to this.
Last updated: 2026-07-03 (reconciled to shipped reality — one-model stack,
recipe-first, triggers, click, voice)._

## One-sentence

The Mac AI that lives in your notch: it **sees** what's on your screen,
you **ask** about it, and it **does** the work — *local software, your
model*: Handle runs on your Mac and talks only to the AI provider you
chose, with your own key.

> **Direction change, 2026-09-19 (my call):** the on-device model was replaced by
> bring-your-own-key providers (Anthropic Claude, OpenAI, or any OpenAI-compatible
> server — a local one means nothing leaves). `PROVIDERS.md` has the architecture,
> decisions and phase log. Sections below that still mention Qwen3-VL / MLX evals
> describe the pre-September on-device era and are kept as history.

## Target user

Mac power users who already pay for Anthropic Claude, or would like to.
Developers, designers, knowledge workers, founders. People who context-
switch between an explainer (ChatGPT), a launcher (Raycast / Alfred),
and an automation tool (Shortcuts / Keyboard Maestro) — and want one
thing instead.

## Three modes — See · Ask · Do

Handle is **one** assistant with three ways to engage it. These are **not
separate features and not a mode switch** — they're facets of a single
notch surface, and the entire point of the product is that they **flow
into one another**. (Build/architecture is still organized by capability;
this is the user-facing mental model.)

You reach all three by typing OR by **voice** — hold the talk key and speak;
the command is transcribed **on-device** (WhisperKit / Whisper turbo-large) and
run exactly like a typed one. Nothing audible ever leaves the Mac — the contrast with
HeyClicky (voice → AssemblyAI, replies → ElevenLabs, screen → Claude) is the
whole point: same interaction, none of the cloud.

### See — ambient, always on (not a thing you trigger)
Handle's eyes are simply open. **Every time you type, it captures the screen
you're looking at and grounds the answer in it** — no shortcut, no button.
"What's this error?" / "summarize this" just work because the current
screen is automatic context on every turn. It decodes errors, translates,
summarizes, explains unfamiliar UI, and can point at an element. The
capture **excludes Handle's own windows** (it sees the apps, not its panel).
(Region capture — the drag-to-select power move — was removed 2026-07-10:
with See ambient, a second capture concept wasn't earning its keep.)

**Intent-gated for speed:** a vision turn costs ~5× a text turn, so Handle
doesn't literally re-encode the screen on every keystroke. A cheap check
on the prompt decides whether to look — screen-referential prompts ("what's
this error?", "summarize this") trigger a capture; self-contained ones
("write a haiku", "what is recursion") answer at text speed. It still sees
*whenever it plausibly matters*; it just skips the look when it clearly
doesn't. (Heuristic today; a small on-device classifier later. The deeper
cost levers — resolution tuning and an encoder/KV cache — are tracked
separately.)

This is the truest form of the product, and since the model moved to the
user's provider it is **never silent**: a screenshot is taken only when the
question is about the screen, sent only to the provider the user chose, and
every send is visible — a caption under the bubble, an eye on the notch,
and a "What was sent" list with thumbnail, tokens and cost. It is also
controllable: **excluded apps** are never captured at all (Handle says so
instead of guessing), and **ask-before-send** puts a confirm card in front
of every screenshot for those who want it. Captures are ephemeral — never
written to disk by Handle. (If we ever persist chat history — store the
*text*, not the raw screenshots.)

**Whole-machine sight, not just the visible screen.** "See" isn't limited to
the pixels currently in front of you. Handle keeps a **window manifest** — a
cheap, pixels-free list of every open window (app, title, which display),
refreshed each turn — so it always *knows what's open everywhere*, even
windows buried behind others or sitting on a second monitor. When you ask
about a specific one — "what's the build error in Xcode?" while Safari is on
top — Handle captures **that exact window** (via ScreenCaptureKit's
`desktopIndependentWindow`, which renders the window's own surface, so
occlusion is irrelevant), not whatever happens to be frontmost. The routing,
cheapest-first:

- Names an open window ("the error in Xcode") → capture *that* window, even if buried.
- Generic screen reference ("what's this?") → capture the visible display under the cursor.
- Asks about the machine ("what do I have open?") → answer from the manifest, no screenshot.
- Self-contained ("write a haiku") → no look at all.

The manifest is near-free (a system query, not a vision turn), so it's always
on; only the targeted/visible capture costs the ~5× vision turn. **Honest
limits** (macOS, not us): minimized windows and windows on *other Spaces* have
no live surface, so they can't be seen without bringing them forward, and a
capture is the window's current viewport, not its scrolled-away content. All
of it runs under the one Screen Recording permission already granted, and
stays ephemeral like every capture. (Today the window is chosen by a heuristic
from your wording; in M3 the model picks it itself via tool-use.)

### Ask — the connective tissue
Type or talk to Handle in the notch. On its own this is ordinary chat — but
that's not its job. Ask is the **layer that steers the other two**: how you
go from *"what's this error?"* (See) to *"ok, open the file and fix the
import"* (Do) in one continuous thread. Chat carries the context — the
captured screen, the active app, the conversation so far — so See and Do
never feel like separate tools. We deliberately **do not** position Ask as
a standalone hero: "another chatbot" is not why Handle exists. Its value is
the glue, not the answers.

### Do — "make it happen"
Tell Handle to act and it executes — natively where it can, via
AppleScript / JXA / URL schemes / Accessibility / shell where it must (the
control ladder in EVALS.md). Schedule a meeting, file an email, set a
reminder, rename a folder of files, drive any scriptable Mac app. One-shot
("add this to my calendar") or recurring ("every Sunday at 9am"). Highest
value *and* highest risk — so every destructive action confirms, and trust
is earned, not assumed.

### How they interconnect — this IS the product

The differentiation isn't any single mode; competitors each nail exactly
one. It's the **seam between them**:

- **See → Ask → Do:** ⌥⌥ a Stripe receipt → "what is this?" → "log it as a
  business expense" → Handle files it. One thread, all three modes.
- **Ask → See:** "what's wrong with my build?" → Handle recaptures the
  terminal, reads the error, points at the failing line.
- **Do → See:** after an automation runs, Handle shows the result on screen
  and explains what changed.

ChatGPT only asks. Raycast / Shortcuts only do. Cluely / screenshot tools
only see. Handle's moat is that all three happen in **one screen-aware
surface on your Mac, with the model you choose** — *the assistant that
sees what you see and acts where you are, on your terms.*

### Which model serves which mode — one provider + recipes

- **See + Ask + Do → the user's provider (Claude by recommendation; OpenAI or a
  compatible server by choice).** One model for everything; native tool calls on the
  action loop; pointing stays select-by-index over the AX list. Cost is visible per
  request and per session. *(History, pre-2026-09:)* one resident vision-language model (Qwen3-VL 4B).
  Chosen over Qwen 2.5-VL 7B and Gemma 3 4B by a head-to-head UI-grounding eval
  (2026-07-02, see EVALS.md): better pointing, half the RAM, faster, and it never
  fabricated a click. It's loaded for See anyway, so Ask (screen-grounded chat) and
  Do (retrieval + param-fill over recipes) add no extra resident model.
- **AppleScript comes from RECIPES, not a second model.** The original plan paired the
  VL model with a Qwen 2.5 Coder model for AppleScript/JXA generation. That's obsolete:
  the recipe-first architecture stores hand-verified AppleScript as parameterized
  templates, so the model RETRIEVES + FILLS rather than generates (the model can't plan
  freeform — proven, see AUTOMATIONS.md). The 14B Coder is also RAM-infeasible on 16 GB Macs.
  Freeform AppleScript generation survives only as a flagged, approval-gated fallback on
  the same VL model.
- **Later (v1.5):** when present, Apple FoundationModels (macOS 26+, ~3B,
  zero disk) offloads intent-routing and light text turns to free the VL
  model, falling back to VL when absent. _This supersedes the
  FoundationModels-first routing sketched in "Smart routing" below, which
  moves from a v1 dependency to a v1.5 optimization._

## Agentic automation — the deeper "Do" · ✅ SHIPPED (core), v2 extends

The user states a *goal*, Handle runs a multi-step recipe toward it, and can
**save, schedule, and trigger** it as a reusable, private, on-device automation.
**Status (2026-07-03): shipped and validated live** — 97-recipe library,
conversational save, time scheduler, and three reactive triggers (a file appears /
an app launches / Wi-Fi joins), all under standing consent with a full audit
trail. This is where Handle stops being a nicer Siri and becomes something no one
else ships. Remaining: more trigger types (window/AX), recipe-library growth,
edit-automation UI.

### Two kinds of "agent" — and where Handle draws the line

**Automation agents — IN SCOPE, the sweet spot.**
Chaining Handle's *own tools* toward a goal:
- "Every morning, summarize my unread mail and add follow-ups to Reminders."
- "When I drop a file in ~/Desktop/Invoices, rename it by date and move it to Documents."
- "Set up focus: quit Slack and Mail, open my project, start a 50-minute timer."

These are sequences of tools we already ship (calendar, reminders, files,
AppleScript, Shortcuts). The model handles them because it never has to plan the
happy path — recipes carry the steps; it retrieves and fills (see below). Natural
language → durable, private automation on this Mac. **This is the differentiator; we
lean all the way in.** (First two examples above = shipped trigger/schedule classes;
the mail-summary one awaits a mail-reading tool.)

**Creative / generative agents — OUT of scope, deliberately.**
"Build me a website", "write a 2,000-word essay", "refactor this codebase." The
model could now do them — the reason is focus, not capability: building a website is
a solved problem in the tools that already do it well; Handle's job is to *automate
your Mac*. We don't chase them.

### How automation agents work

1. **Agent run — recipes as tools inside the loop. ✅** *(Since 2026-09-20; the
   recipe-first gate below is history — it was built for an on-device model that
   could select and fill but not plan, see AUTOMATIONS.md.)* Today the agent loop plans
   freely with every tool, and the matching recipes are offered to it as
   `run_recipe`. Originally: given a goal, Handle **retrieved a
   proven recipe** (the model picked it from a shortlist by index — the same
   select-by-index trick that made pointing work) and **fills its parameters**. The
   resolved recipe is shown for ONE up-front approval, then executed. No matching
   recipe → an honest "I don't have a recipe for that yet." The **recipe library is
   the architecture**: 97 live recipes (8 built-in + 87 mined from
   raycast/script-commands via `tools/mine_raycast.py` + `curate_recipes.py`, vetted
   per-Mac), retrieval validated 13/14 at scale (EVALS.md).
2. **Save ✅** — a goal phrased with a schedule or event ("every day at 6pm…",
   "whenever a PDF lands in Downloads…") is parsed, matched to a recipe, filled,
   and saved as `{recipe id + params + schedule/trigger}` after one confirm card.
3. **Schedule / trigger ✅** — recurring times AND local events (fileAppears /
   appLaunches / wifiConnects — event-driven, no polling). A saved run executes
   under the **standing consent** granted at save — no cards at fire time; every
   run audited. TCC dialogs are **primed at save time** (PermissionsService) so an
   unattended run never stalls on a hidden permission prompt.
4. **Manage ✅** — Settings → Automations: list, enable/disable, delete (+ run
   history via the audit log / Activity). Edit-in-place: not yet built.

### Shortcuts.app integration

- **Trigger** any installed Shortcut by name via the documented `shortcuts run`
  CLI — trivial; ships as a `run_shortcut` tool (`shortcuts list` enumerates).
- **Create** Shortcuts from Handle is deferred (the `.shortcut` format is
  undocumented). Handle automations live in Handle's own store and can *call*
  Shortcuts, giving reach without owning the format.

### Why more power demands more safety (and we already built the floor)

Automation agents multiply Handle's reach, so the safety story matters *more*: (a)
every automation is approved once, in full, at creation; (b) every step — live or
scheduled — is recorded in the **audit log**; (c) scheduled runs never invent new
consequential steps beyond the approved recipe (a re-plan that needs a new
consequential tool re-prompts); (d) a global **"pause all automations"** switch.
The **preview-diff + audit log** shipped in the core product are the foundation
this is built on.

_Implementation plan: see **AUTOMATIONS.md**._

## Always-present surface — the notch

Lives as a thin black pill at the top center of the active display.
Visually merges with the hardware camera notch on MacBook Pro / Air;
synthesizes the same shape on non-notch displays.

- **Closed**: small pill with the Handle lightbulb on the left wing.
- **Expanded**: chat panel descending below the notch, with
  conversation, input, and tool results. (Captures are ambient context —
  deliberately NOT rendered as thumbnails in the transcript; the
  "Looking…" label signals a capture happened.)
- Hover → open. Cursor leaves → retract. Pin (📌) to stay open.

The menubar status item is removed in favor of the notch. Right-click
the notch for app-level menu (Settings, About, Quit).

## Memory layer (design — not yet built)

Handle remembers user-specific facts across sessions in a local SQLite
file (`~/Library/Application Support/Handle/memory.db`):

- Preferences: "user usually schedules in PST, 30-min slots,
  9am–6pm window"
- Contacts: "Mary = Mary Chen, mary@acme.com"
- Categorization habits: "Stripe receipts → 'Business expenses' in
  Finance app"
- Recent automations and their run history

Each turn, the system prompt injects relevant memory entries. User can
view, edit, or wipe the memory in Settings. **Never leaves the Mac.**

## Private AI architecture — "local software, your model"

Handle is a single shippable product with one privacy line, kept where it
is true and dropped where it isn't (2026-09-19):

**On this Mac, no exceptions:** screen capture, OCR, accessibility reads,
the window manifest, voice transcription (WhisperKit), memory (`memory.db`),
chat history, the audit log, recipes, your own tools and instructions, MCP
servers you run. Voice audio never leaves the Mac. Handle stores nothing
anywhere else.

**What leaves, and only this:** the model turn — the text of the current
conversation plus, when the question is about the screen, that screenshot —
sent straight to the provider **you** chose with **your** key. No Handle
server, no proxy, no telemetry, no account with us, **no default provider**
(nothing is preselected; the app never switches on its own). Every send is
visible (bubble caption, notch eye, "What was sent" with tokens and cost)
and controllable (excluded apps are never captured; ask-before-send).

**Fully local is a supported path, not the headline:** point the
OpenAI-compatible adapter at LM Studio or Ollama and nothing leaves the Mac
at all. Settings and the identity say so honestly ("$0 · local"); we never
claim it as the default experience.

**User-directed traffic to the user's own services stays fine** (clarified
2026-07-03): Google Calendar via Internet Accounts, opening URLs, MCP
connectors with tokens in the Keychain — accounts the user chose, like Apple
Calendar syncing to iCloud.

### The shipping stack

| Layer | What | Where it runs |
|---|---|---|
| **Everything (See+Ask+Do)** | The user's provider — Claude (`claude-sonnet-5` by default; Opus selectable), OpenAI, or any OpenAI-compatible server | Provider (or a local server) |
| **Voice in (STT)** | WhisperKit large-v3-turbo (CoreML), ~0.6 GB, downloaded on first talk | This Mac |
| **Everything else** | Capture, OCR, AX, memory, history, audit, recipes, MCP | This Mac |

The intelligence that a model fleet would have carried still lives in
**recipes** (hand-verified, parameterized AppleScript) and **select-by-
index** interfaces — now because they are auditable and cheap, not because
the model can't do otherwise.

### Backend

- `Handle/AI/` — provider-neutral message/tool/event types, `AnthropicProvider`
  (Messages API, prompt caching), `OpenAIProvider` (Chat Completions + custom
  base URL), `CloudEngine` (turns, usage, sent log). Raw `URLSession` + SSE.
- **WhisperKit** (argmax) for CoreML speech-to-text.

### Minimum hardware

- **macOS 26+** (current deployment target) on any Mac that runs it
- Apple Silicon for on-device voice (WhisperKit); everything else works on Intel —
  onboarding shows a soft note, never a refusal
- ~1 GB free disk for the voice model

There is no memory floor any more: the model is not on the Mac.

### AppleScript reliability — how it's actually solved (shipped)

Models are unreliable at AppleScript because training data is scarce. The
answer that shipped is **recipe-first** (AUTOMATIONS.md), which inverts the
problem — the model never *writes* AppleScript on the happy path:

1. **Recipe library ✅** — 97 hand-verified, parameterized scripts (mineable to
   200+; `tools/mine_raycast.py` + `curate_recipes.py`). The model retrieves by
   index and fills typed params. Freeform generation survives only as a
   flagged, approval-gated fallback.
2. **`.sdef` dictionary injection on retry ✅** — when a freeform script errors,
   the target app's condensed scripting dictionary is injected into the retry
   so the fix uses real vocabulary. (The original install-time RAG index is
   unnecessary at current scale.)
3. ~~HandleCoder fine-tune~~ — obsolete: there is no Coder model to fine-tune.
   If a moat-grade tune ever makes sense, it would target the VL model's
   recipe-retrieval/fill behavior, not script generation.

### Audit log & preview-diff ✅

Every tool call, recipe run, automation fire, and click recorded in
`~/Library/Application Support/Handle/audit.jsonl` (timestamp, tool, args,
outcome, confirmed). Preview-diff before file mutations; the resolved
AppleScript shown in full on every recipe card; Settings → Activity surfaces
the recent log. No consumer Mac AI assistant currently ships this — it's our
headline privacy/safety differentiator. (Per-tool approval scopes in Settings:
planned, not built.)

### Model file management

Models live in `~/Library/Application Support/Handle/models/`, NEVER in
the app bundle. Downloaded from Hugging Face on first run via the `Hub`
Swift package, with a disclosure card before download (model name, GB,
ETA, disk requirement) — industry standard pattern (MacWhisper,
LM Studio, Draw Things all do this). Settings → Storage relocator lets
users move models to an external drive.

### Hardware-tier auto-detect

At first run, detect chip + RAM and recommend the appropriate tier.
Models labeled "Recommended for your Mac" / "Slow on your device" /
"Not enough RAM" (Jan.ai pattern). Refuse to load a model that would
trigger heavy swapping — protect the user from the "Handle is so slow"
1-star review.

## Mac-app reach (what we can automate)

Handle can automate ~90% of the Mac apps a power user has open, via
six layers:

| Layer | What it does | Examples reachable |
|---|---|---|
| AppleScript dictionaries | Direct scripting API | Mail, Calendar, Reminders, Notes, Messages, Safari, Chrome, Spotify, Things, OmniFocus, Bear, Adobe CC, MS Office, Logic, Final Cut |
| URL schemes | App-registered `xyz://` URLs | Slack, Obsidian, VS Code, Discord, Zoom, Notion, Telegram, 1Password (limited) |
| Web APIs (via curl) | Cloud apps' REST APIs | Linear, Asana, Jira, Notion, Stripe, GitHub, Google Workspace, Slack |
| Shortcuts.app actions | Trigger any installed Shortcut by name | Things, OmniFocus, Drafts, Streaks, Carrot Weather |
| Accessibility API | Read / click / type on any visible UI | Anything on screen — Discord, Teams, Figma desktop, sandboxed apps |
| Shell | Any installed CLI | `gh`, `gcloud`, `aws`, `git`, `npm`, `ffmpeg`, `jq`, user scripts |

## Positioning

| vs. | Their thing | Handle's thing |
|---|---|---|
| **Clicky** (free OSS) | Screen explainer + voice, sends to Claude API | Explains + acts + automates; your own key, every send visible, nothing stored off the Mac. Free, open source. |
| **Cluely** (paid SaaS) | Meeting copilot, server-hosted (had a breach in 2025) | No server at all: the model turn goes straight from your Mac to the provider you chose. |
| **Apple Intelligence** | Writing & image generation, mostly on-device | System automation with real tools, agents and a consent card for every action. |
| **Raycast AI** | Launcher + cloud AI commands | Screen-aware + notch-resident + acts on the screen; bring your own key. |
| **Shortcuts.app** | Drag-drop automation builder | Natural language → automation; your Shortcuts become Handle tools too. |
| **ChatGPT Mac app** | Conversational AI in a window, cloud only | Sees your screen and acts on your Mac; stores nothing anywhere else. |

**The single sentence that differentiates Handle from everyone:**
*"The Mac AI that sees your screen and runs your Mac — local software,
your model, your key; every send visible, nothing stored anywhere else."*

## Principles (decide every feature against these)

1. **Mac-native first.** No Electron. No web wrappers. macOS APIs over
   reinvention. If AppKit has it, use AppKit.
2. **Local software, your model.** Handle's own processing stays on the
   Mac; only the model turn goes to the provider the user chose with their
   own key. No Handle server, no proxy, no telemetry, no default provider.
   (User-directed traffic to the user's own services is fine — see
   "Private AI architecture" for the precise line.)
3. **Show what you sent.** Every request that leaves is visible — caption,
   notch eye, "What was sent" with cost — and controllable (excluded apps,
   ask-before-send). Silence is never an option.
4. **Permission-gated automation.** Every destructive operation
   confirms. First run of a generated AppleScript shows a preview.
   Permissions staged with rationale during onboarding.
5. **One material throughout.** Liquid Glass everywhere. One button
   style. One type ramp. One accent color.
6. **The notch is the brand.** No app logo pasted on every screen. The
   presence IS the identity.

## In scope for v1 (the only shipping version)

There is no v1.0 / v1.5 split anymore. Handle ships once, with
bring-your-own-key AI from day one — local software, your model.

**Shipped + validated (as of 2026-07-03):**
- Notch UI (closed / expanded, hardware-notch detection per screen) + the
  metaball pointer (birth/suck) — the brand animation
- Ambient sight: intent-gated screen capture on every turn, window manifest,
  targeted occluded-window capture (⌥⌥ region capture shipped here, later
  removed — 2026-07-10 my call)
- **Pointing** (select-by-index highlight) and **Click** (AXPress + synthetic
  fallback, highlight → confirm card → press → audit)
- **Voice**: push-to-talk (hold ⌥; was ⌃⌥Space until 2026-07-10) → on-device Whisper STT → same loop;
  listening = the pointer animation with dictation bars. (Spoken replies were
  removed 2026-09-20 — the system voice wasn't good enough; voice is input-only.)
- Built-in tools: calendar, reminders, files (workspace-scoped), drafts
  (mail/iMessage compose — never send), open url/file, run_applescript
  (.confirm), optional shell toggle
- **Recipe engine + 97-recipe library** (mining + per-Mac curation pipeline)
- **Automations**: conversational save → time schedules + reactive triggers
  (fileAppears / appLaunches / wifiConnects), standing consent, Settings
  management UI
- **Permissions**: TCC status panel + save-time Automation priming
- **Audit log + preview-diff** — the headline privacy/safety differentiator
- MLX backend, one-model stack (~3.2 GB), model download on first use

**Shipped 2026-07-06 (was "remaining"; per-feature evidence in the changelog):**
- Conversation persistence (SQLite, text-only snapshots — never screenshots)
  + History page in the ⋯ menu (reopen/continue, delete, clear-all)
- Memory layer: explicit facts ("remember that…" / "forget…" / Settings →
  Memory inspector), keyword-scored per-turn injection folded next to the
  user's text (before the tool spec the 4B ignored it — see changelog)
- First-run onboarding in the notch panel: welcome (soft voice note on Intel),
  staged permission prompts with rationale, **connect your AI** (two equal
  provider cards, nothing preselected, key + live test, skip allowed)
- Edit-automation UI (in-place: name, time/days, trigger fields, params JSON)
- `run_shortcut` / `list_shortcuts` tools (+ the freeform prompt now actually
  offers them; orphaned `run_shell` dispatch wired)
- Settings: memory inspector + model storage relocator (one huggingface base
  for VL + Whisper, moveable to an external drive)

**Remaining for v1 ship:**
- Distribution: Developer ID + notarization, Gumroad/Paddle licensing +
  14-day trial, Sparkle auto-update, opt-in crash reporting (needs my
  accounts/certificates)

(Appearance toggle: CLOSED 2026-07-06 — my decision, no light mode.
The notch is solid-black by design; `.darkAqua` stays forced.)

## In scope for v2 — **pulled into pre-ship scope (my decision 2026-07-07)**
## (v1-as-was didn't clear my ship bar; build these BEFORE launch)

- **MCP client, routed through the recipe engine** (decided 2026-07-03; build
  order #1) — the integrations story: community MCP servers run locally, tokens
  in Keychain, their tools surfaced as recipe-like entries (prefilter →
  select-by-index → fill → confirm → audit). Inherits hundreds of connectors
  without a cloud backend and without handing the small model an open-ended
  tool list.
- **Routines — scheduled AGENTIC tasks** (2026-07-07): "every morning,
  summarize my emails." Today's scheduler fires deterministic recipes; a routine
  fires a model RUN on a schedule — gather via tools/MCP (e.g. mail) → the local
  model synthesizes (summary/digest) → the result lands in the notch
  notification center. Same standing-consent + audit rules as automations. The
  mail-summary example under "Automation agents" graduates from aspiration to
  this feature; MCP is the natural source of the gather tools, so Routines
  builds on the MCP client.
- More reactive triggers: windowMatches (AX), calendar-event-soon, power/lock
  events — the full TriggerEngine roadmap (REPOS.md §3)
- Model choice follows the provider's releases; the pointing eval (EVALS.md) is re-run per model before the default changes
- Recipe library growth beyond 200 + retrieval-at-scale hardening

## Out of scope (deliberately closed doors)

- **Handle-hosted AI** — no Handle Cloud, no proxy, no accounts, no
  subscription tier. The user's own key, or their own local server; never
  ours in the middle.
- **Wake word ("Hey Handle")** — dropped (2026-07-10). Push-to-talk
  (hold ⌥) and the click-to-talk mic cover voice; an always-on microphone
  sits badly next to the privacy promise and costs battery on a 16 GB Air.
- **Mac App Store SKU at launch** — direct distribution only. MAS
  comes later only if there's specific demand.
- **Real Shortcuts.app integration** — file format is undocumented;
  AppleScript covers the use cases more powerfully
- **Team sync, multi-device, cloud memory** — privacy positioning is
  the moat; cloud sync would undermine it
- ~~Custom MCP server installation — deferred indefinitely~~ →
  **superseded 2026-07-03**: an MCP *client* (servers run locally, routed
  through the recipe engine) is now the v2 integrations story — see v2 scope.
  What stays out: any Handle-hosted connector backend that proxies user data.
- **iOS, Windows, Linux companions** — Mac-native is the brand
- **Long-term episodic memory** — local fact table is enough
- **Bundling Gemma, Llama, or other open models we didn't pick** —
  Qwen family is current SOTA for our use case; revisit per release
  cycle, never multi-bundle
- **8 GB RAM Macs / pre-M1 Macs** — not the target market; first-run
  detection refuses to install rather than degrade gracefully

## Open evaluations — status

The v1 model choice is now LOCKED to Qwen3-VL 4B (one resident VL model), decided
empirically on Handle's real workload rather than published benchmarks — see EVALS.md.
Updated below to reflect what that settled and what genuinely remains:

### Eval 1 — Vision / UI grounding · ✅ grounding done; content-read + Holo2 remain

The load-bearing task (UI grounding — pick the right on-screen element) is DONE: a
drift-guarded pointing battery on Finder + dense third-party UIs, plus a screen-reading
pass, chose Qwen3-VL 4B over Qwen 2.5-VL 7B and Gemma 3 4B (see EVALS.md). The old
candidate list (8B/32B, MiniCPM-V, a Claude cloud reference) is superseded — 32B won't
fit 16 GB, and a cloud reference is off-brand for a local-only product. Two follow-ups:
- **Holo2-4B** (Hcompany, Apache-2.0) — a Qwen3-VL-4B *fine-tune* purpose-built for GUI
  grounding (ScreenSpot-Pro ~57% vs a general VLM's low scores). Same architecture, so
  it's a **drop-in for the mlx-swift loader** — only needs a 4-bit MLX quant produced.
  Prime candidate to beat the current model on the dense-list over-selection watch-item.
  Caveat: it's a "Thinking" variant (emits reasoning tokens → latency/suppression cost).
- **Content extraction** — 30–50 dense screenshots (Mail, IDE stack traces, foreign
  text, Excel/Adobe) with ground-truth Q&A, to measure *reading* accuracy beyond grounding.

### Eval 2 — Recipe retrieval reliability (replaces "AppleScript generation")

Recipe-first mooted the old "generate 50 scripts, % that compile" eval — AppleScript is
now hand-verified and stored, not generated. The number that matters is RETRIEVAL: across
a ~200-recipe library, does keyword-prefilter + select-by-index find the right recipe?
Eval: 30 plain-English goals → expected recipe id; score top-1 and "correct-or-graceful-
decline." Param-fill robustness (dates, paths) rides along. This gates shipping the mined
library (AUTOMATIONS.md open Q2/Q3).

### Eval 3 — Tool-call reliability · mostly addressed

The lenient parser (`parseToolCall`: JSON + function-call syntax, anchored on known tool
names; `intArg`/date/priority coercion) already absorbs the local model's format drift; 121
self-tests cover it. A 100-turn "valid call + correct tool" measurement is worth running as
a regression guard, but it's no longer a model-selection gate.

**The model selection is locked on empirical numbers (EVALS.md).** Re-open it
only with new evidence — e.g. the parked Holo2-4B grounding fine-tune, or the
dense-list over-selection watch-item showing up in real use.

## Pricing

One product, one price.

- **Direct download via Gumroad or Paddle**: **€49 lifetime + 14-day
  free trial.** No subscription, no recurring fees, no per-query costs
  ever.
- **Major version upgrades** (v2.0, v3.0): existing customers pay 50%
  to upgrade. Funds ongoing development without abusing buyers with
  recurring billing.
- **No Mac App Store at launch.** Direct distribution only. We may add
  MAS later as a secondary channel if demand exists.
- **No Handle-hosted AI, ever.** Bring your own key (or your own local
  server); no proxy, no subscription cloud tier, nothing of yours on our side.

No account creation, no telemetry by default (opt-in only),
no recurring obligations.

## Marketing copy

**Headline:** The Mac AI that sees your screen and automates your apps.
Local software, your model.

**Subhead:** Lives in your notch. Explains what you're looking at, clicks
what you name, and runs the automations you describe — by keyboard or
voice. Your own API key, every send visible, nothing stored anywhere but
your Mac. No accounts. No subscriptions.

**First-run prompt:** Try ⌥⌥ to capture anything on your screen —
Handle will explain it. Or type a command and it'll get it done.

**One-liner for App Store / Product Hunt:** Handle is the Mac AI that
runs on your Mac with the model you choose — your key, your screen shared
only when you ask, every send in plain sight.

## Success metrics (6 months post-launch)

- 1,000 paying customers
- Trial-to-paid conversion > 15%
- ≥ 50% of paying users invoke Handle at least 3× per week (active
  retention)
- Crash-free sessions > 99%
- ≥ 10 organic mentions / screenshots per week on Twitter / Pinterest /
  Hacker News / r/MacApps

## How to use this document

When considering ANY new feature, ask:

1. Does it advance See, Ask, or Do — or, best of all, the **seam**
   between them?
2. Does it serve the target user (Mac power user, BYOK-comfortable)?
3. Does it respect the five principles?
4. Is it in scope for v1, or does it belong to v1.1+?

If the answer to any of (1)–(3) is no, the feature does not belong in
Handle. If (4) lands in v1.1+, log it but do not build it now.
