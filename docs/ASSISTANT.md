# Handle — from notch helper to full Mac assistant (plan)

**Status:** decided 2026-09-20 (the brief: "it should be able to do everything and create and
run its own agents"). Builds on `PROVIDERS.md` (the model is the user's provider; native
tool calls; See consent). This doc is the plan + decisions + phase log for the agent side.

## What's true today, and what holds it back

Handle already reaches almost everything on a Mac: files, calendar, reminders, drafts,
Shortcuts, `run_applescript` (any scriptable app), `run_shell` (any CLI), MCP (any service),
297 recipes with schedules and triggers, Routines, memory, audit. What limits it is the
**leash** the loop inherited from the 4B model, and the absence of **agent primitives**:

| Rail (HandleApp.swift `runToolLoop`) | Why it existed | What it costs now |
|---|---|---|
| `maxSteps = 5` | a 4B loops forever | a real task needs 10–30 steps |
| `terminalDone` after ONE consequential action | a 4B double-acts | "quit Slack and Mail, open Downloads" = three turns |
| only the FIRST tool call per step is kept | a 4B emits one | no parallel reads; Anthropic requires results for every call in a message |
| repeat guard hard-stops on the 2nd identical call | a 4B re-issues calls | a legitimate re-check after a change is blocked |
| recipes / MCP **front-run** the loop and own the turn | retrieval beat freeform planning | the model can't combine a recipe with a tool, or plan around them |
| click/point only as a special first step | index-select was the only reliable pointing | no hands mid-task: no type, keys, scroll, read-window |
| `recapture_screen` returns text only | tool results are text | the model never sees the new screenshot |
| no web | privacy line | can't look anything up |
| Routines = 3 read-only steps + a summary | a 4B can't be trusted unattended | agents can't act, be created by the model, run in the background, or be reviewed |

## Principles (added to PRODUCT.md's)

- **Every action is still visible and confirmable.** Longer runs, not looser consent. A
  confirm card per consequential action; standing consent is explicit, per agent, revocable.
- **Budgets, not hopes.** Each turn and each agent run has a step cap and a dollar cap;
  both visible; hitting one ends the run with a plain answer, never a silent stop.
- **Recipes stay the fast path, not the gate.** The model can call a recipe as a tool
  and combine it with anything else.
- **One loop.** User turns, sub-agents, routines and background tasks run the SAME
  `runAgentLoop` with different policies (tools, budget, consent). No second mini-loop.

## Phases

| # | Scope | Files |
|---|---|---|
| 1 | **Loosen the loop.** Step cap 5→30 + per-turn dollar budget (`AgentSettings`, both visible); every tool call in a step is executed and every result returned together (parallel calls); `terminalDone` gone — a confirmed action feeds its result back and the run continues (decline still ends it); repeat guard = hint on the 2nd identical call, stop on the 3rd; image-bearing tool results (`recapture_screen` returns the screenshot to the model). | `HandleApp.swift`, `Handle/AI/AgentSettings.swift`, `AgentPrompting.swift`, `AIProvider.swift`, `AnthropicProvider.swift`, `OpenAIProvider.swift`, `ToolRegistry.swift` |
| 2 | **Hands and eyes.** `ScreenTools`: `list_windows`, `focus_app`, `read_window` (numbered AX elements, also refreshes the click list), `click_element{index}` (highlight → card → press, mid-loop), `type_text` (clipboard paste, clipboard restored), `press_key{key, modifiers}`, `scroll`, `read_screen_text` (OCR). `screenshot` = `recapture_screen`. | `Handle/ScreenTools.swift`, `AccessibilityProbe.swift`, `SystemKeyboard.swift`, `ToolRegistry.swift` |
| 3 | **Recipes, MCP and the web inside the loop.** `run_recipe{id, params}` with the keyword-prefiltered candidates listed in the turn prefix; configured MCP tools as native tools (`mcp__<server>__<tool>`, always confirm); the recipe/MCP front-running paths removed. `fetch_url` (local, text-extracted, capped) for every provider; Anthropic's server-side `web_search` behind a Settings toggle. | `HandleApp.swift`, `MCPService.swift`, `Handle/WebTools.swift`, `AnthropicProvider.swift`, `SettingsView.swift` |
| 4 | **Agents as tools.** `runAgentLoop(conversation, policy)` extracted from `runToolLoop`; `AgentPolicy {tools, maxSteps, budgetUSD, standingConsent}`; tools `save_automation` (schedule / trigger / routine goal), `list_automations`, `run_automation`, `delete_automation`; `run_subagent{goal, tools, max_steps}` (child loop, result = tool result); `run_in_background{goal}` + a task ledger with notch progress; Routines run the real loop with their policy (read-only unless standing consent was granted on the card). | `Handle/AI/AgentPolicy.swift`, `Handle/TaskLedger.swift`, `Automation.swift`, `HandleApp.swift`, `SettingsView.swift` |
| 5 | **Review and safety.** Settings → Agents: each automation's policy, last run, cost, audit; the task ledger; a kill switch; per-agent standing consent editable and revocable. Self-tests + harness for every phase. | `SettingsView.swift`, `AuditLog.swift` |

Order matters: 1 makes multi-step work at all; 2 gives the model hands; 3 lets it plan
across everything; 4 lets it delegate and persist; 5 makes unattended runs reviewable.

## Decisions (2026-09-20)

- **Not for sale, not on the App Store.** Handle is a free, open-source personal project on
  GitHub (portfolio). Direct distribution only (the App Sandbox forbids what Handle does:
  Accessibility control, keystrokes, shell, AppleScript to arbitrary apps, MCP servers).
  Everything in PRODUCT.md about pricing, licenses and the App Store is void.
- **Fix all the bugs, then make it customizable:** a user-tools folder (script-backed tools
  registered as native tools), custom instructions, trust settings (tools on/off,
  auto-approve, per-automation budgets).
- (earlier the same day)

- Recipes are no longer a gate; the loop decides. (The library stays and grows.)
- Web access is opt-in per Settings; fetching a page the user named is fine by default.
- No agent acts unattended without standing consent granted on a card the user saw.

## Status

- Phase 1 — DONE 2026-09-20 (361/361; parallel calls + image results live; screen capture blocked by a TCC denial on the Debug build).
- Phase 2 — DONE 2026-09-20 (366/366; `focus_app` live; click/type/read need Screen Recording + Accessibility re-granted).
- Phase 3 — DONE 2026-09-20 (372/372; `fetch_url` + `run_recipe` live; 18 MCP tools joined the loop).
- Phase 4 — DONE 2026-09-20 (378/378; `list/delete_automation` live, routines on the real loop).
- Phase 5 — DONE 2026-09-20 (380/380; sub-agent + background task live; consent toggles, last runs, Run now, kill switch).
- Review — DONE 2026-09-20 (384/384; 10 findings fixed: consent-gated recapture, no unattended consent minting, depth/re-entrancy guards, parent ∩ child tools, ledger-tracked routines, per-request cost, honest audits, read-only unattended toolsets).
- Customization — DONE 2026-09-20 (390/390; `CUSTOMIZING.md`: user tools from JSON files, instructions, per-tool on/off + don't ask, per-routine budgets).

**All five phases shipped 2026-09-20.** Open items for me: re-grant Screen Recording and
Accessibility to the Debug build (phase 2's click/type/read-window tools are untested until then),
glance at the new Settings rows in the notch, and decide when to commit.
