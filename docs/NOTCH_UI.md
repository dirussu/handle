# Handle — Notch UI Spec

_The interaction + layout spec for Handle's notch-resident UI. Companion
to PRODUCT.md (vision) and EVALS.md (engine). Form reference: Boring
Notch (`~/Downloads/boring.notch-main`). Handle keeps Boring Notch's
interaction shell and replaces its content (media utility → AI assistant)._

---

## Core model

Handle lives in the MacBook notch — on notch-less Macs / external displays,
a synthesized pill at top-center of the screen. **Two states**, matching
Boring Notch:

- **Closed** — a pill sized to the hardware notch (+ small wings). A
  *live status surface*, not a static logo.
- **Open** — a panel that drops below the notch: the assistant surface.

Corner radius animates between states. Top edge is square (merges with
the hardware notch's straight bottom edge); bottom corners rounded.

---

## The notch is the only surface (decided)

Handle has **no menu-bar icon, no Dock icon, and no separate windows** — the
notch is the entire interface. The app stays an accessory (LSUIElement):

- **Settings, About, and Quit live in a ⋯ menu** at the top-right of the open
  panel (a custom solid-black dropdown — not a system menu). Settings and
  About open as **pages within the notch**: the panel cross-fades, a back
  chevron (or ESC) returns to chat. Quit terminates.
- **Entry points are hovering the notch and `⌥⌥`.** There is no status-bar
  item to click and no `⌘,` Settings window.
- Removed in this pass: the `NSStatusItem` menu-bar icon, the standalone
  Settings/About `NSWindow`s, and the debug submenu. `NotchController` hosts
  everything; `NotchViewModel.route` (`chat | settings | about`) drives which
  page the open panel shows.

**Consequence — first-run is now mandatory.** With no menu-bar icon
advertising that Handle is running, a new user has nothing pointing them at the
notch. The first-run coachmark (teach "hover the notch / `⌥⌥`") moves from
nice-to-have to required.

---

## Closed pill — a live status surface

No glyph, no logo. Idle, the pill is just the bare notch — it blends
invisibly into the hardware cutout ("never in the way"). Status is shown
through the notch's *edge*, not its face:

| Situation | Closed-pill shows |
|---|---|
| Idle | Nothing — bare notch, invisible against the hardware |
| Task running | **A white comet traces the notch perimeter** — a glowing head with a gradient tail travels around the notch's outline. The signature "Handle is thinking" visual. |
| Task finished, panel closed | A system notification carries the answer — no on-pill peek (the earlier "✓ Done" peek was removed as redundant). |

The traveling comet is Handle's identity moment — it makes the physical
notch itself come alive while working, rather than stamping a logo on it.

### Comet animation — technique
Stroke the `NotchShape` path; animate a bright segment around its
perimeter over a base faint outline:
- A short arc (via `.trim(from:to:)` with both endpoints advancing, or a
  rotating `AngularGradient` masked to the stroke) travels continuously
  around the path while a task runs.
- Pure white, thin line (~2pt), soft glow (white-only per DESIGN.md).
- Loops smoothly; speed conveys "active" without being frantic.
- On task completion: one final fade to idle. If the panel was closed, a
  system notification delivers the result.

> Non-notch Macs: the bare synthesized pill at top-center has no hardware
> to hide behind, so idle needs a *minimal* resting cue (a faint static
> outline) or it reads as a black glitch. Decide during build.

---

## Entry points (dual — both first-class)

1. **Capture** — `⌥⌥` (double-tap Option) or drag-to-select → panel
   drops open showing the captured thumbnail + streaming explanation.
   The "explain / act on what I'm looking at" hero.
2. **Input** — hover-to-open (below) or `⌥Space` → panel opens with the
   text field focused, ready to type a command/question ("remind me at
   3pm", "what's this error", "summarize this"). The "ask / act /
   automate" path.
3. **Voice** — deferred (v1.1): hold a key → speak.

Both are taught in first-run onboarding — now **required**, since removing the
menu-bar icon left nothing else to signal Handle is running (see "The notch is
the only surface").

---

## Open trigger — hover-to-open, with dwell

- Cursor must **rest on the pill ~0.25s** (dwell) before it opens — NOT
  on flyby. Prevents the assistant popping open every time the cursor
  crosses top-center. (Boring Notch uses a delayed hover work item.)
- **Click** also opens immediately (no dwell).
- **Auto-close**: when open and the cursor leaves, close after ~0.5–0.7s,
  UNLESS:
  - the panel is **pinned** (user clicked the pin), or
  - a **task is streaming / awaiting confirmation** (never yank the panel
    away mid-answer or mid-decision).
- Haptic feedback on open/close (`.sensoryFeedback(.alignment)`).

---

## Open panel — the assistant surface

Essentially today's `FloatingPanel` content, re-anchored to drop from the
notch instead of floating near the cursor:

- **Top**: no persistent header. A fresh chat shows a time-of-day greeting
  ("Good evening — what can I help with?") that disappears on the first
  message; a ⋯ button sits top-right (Settings / About / Quit). On a
  Settings/About page this row becomes a back chevron + title.
- **Body** (scrollable): the conversation —
  - captured screenshot thumbnail (if the turn began with a capture)
  - streaming assistant text
  - tool-result cards ("✓ Created event: …")
  - confirmation cards for destructive actions (Cancel / Confirm)
- **Footer**: input bar — type a follow-up or a new command. Focused on
  open when entered via the input path.

Panel grows to fit content as text streams (the `relayoutToFit` fix from
M1), capped at a max height with internal scroll.

### Modes within open (deferred to when automation lands)
A slim toggle: **Chat** (default, v1) · **Automations** (saved recurring
tasks). v1 ships Chat only; Automations tab arrives with M3 automation.

---

## Every display — including external monitors

Handle lives on **every** connected display, not just the MacBook screen, so
the user can reach it from whatever screen they're working on. Decided
during M2; built in `NotchController`.

- **One pill per display**, created at launch and re-mirrored automatically
  when displays change (plug/unplug, resolution, arrangement).
- **One shared Handle brain** — the same conversation + working state are
  broadcast to every display; you're always talking to the same assistant.
- **Independent open/close per display** — hovering monitor B's pill opens
  it on B only; the working comet shows on all pills at once.
- **Capture / Ask opens on the display under the cursor.**
- The MacBook pill merges with the hardware notch; external displays
  **synthesize** the same pill at top-center (`auxiliaryTopLeftArea`
  detection → fallback 200×32). On an external there's no cutout to hide in,
  so the idle pill is faintly visible — a candidate for "hide-until-hover on
  external displays" later (see Open questions).

---

## v1 scope

- Closed pill: bare idle + working comet
- Hover-to-open (dwell) + click + auto-close + pin
- `⌥⌥` capture entry · hover-to-open input entry
- Open panel: greeting + ⋯ menu / conversation body / input footer; Settings & About as ⋯ pages
- Notch + synthesized-notch (non-notch) support
- Replaces the floating-near-cursor panel as the primary surface

## Deferred

- Automations tab (with M3)
- Voice entry (v1.1)
- "Hide-until-hover" for the idle pill on external displays (no hardware
  notch to hide in, so the bare pill is slightly visible)
- Closed-pill live activities beyond the working comet (progress, glanceable status)

---

## Open questions to resolve during build

1. **Onboarding for dual entry** — how to teach both `⌥⌥` (capture) and
   `⌥Space`/hover (input) without overwhelming first-run. Likely a
   one-time coachmark on the pill.
2. **`⌥Space` conflict** — Spotlight is `⌘Space`; `⌥Space` is usually
   free, but verify and make it rebindable.
3. **Does hover-to-open ever feel intrusive in practice?** Dwell tuning
   (0.25s) is the lever; may need user-configurable or a "click-only"
   setting if testing shows annoyance.
4. **Capture vs open race** — if a capture fires while the panel is open
   from a prior turn, append to the same conversation or start fresh?

---

## Existing starting point

`Handle/NotchMockupView.swift` already prototypes the closed/expanded pill
shape, hover behavior, and spring animation from earlier in the build.
It evolves into the real notch panel (replacing `FloatingPanel` as the
host) rather than being rebuilt from scratch.
</content>
