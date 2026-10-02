# Handle — Cloud provider migration plan (BYOK: Anthropic + OpenAI)

**Status:** decided 2026-09-19 (my call); **all five phases shipped the same day** — see
§Status. Supersedes the "local AI, no BYOK, no
exceptions" line in `PRODUCT.md` §Private AI architecture / Principle 2 / Out of scope.
**Why:** the 4B on-device model is the ceiling on "Do" (can't plan, can't use tools
natively, no system prompt, 16 GB gate, 2.5 GB download). Cloud models fix the agent
side outright. Cloud was the original plan (`../PLAN.md` decision 2); local was a pivot.

## New privacy line — "Local software, your model."

The local story is kept wherever it stays true, and dropped wherever it doesn't.

**Still true, still said (on-device, no exceptions):** screen capture, OCR,
accessibility reads, window manifest, voice transcription (WhisperKit), speech output,
memory (`memory.db`), conversation store, audit log, recipes, MCP servers you run.
Voice audio never leaves the Mac. Nothing is stored anywhere but this Mac.

**What leaves, and only this:** the model turn — the text you typed plus the screenshot
for that turn when the prompt refers to the screen — sent straight to the provider *you*
picked, with *your* key. No Handle server, no proxy, no telemetry, no account with us.
**Every capture is visible** (indicator + "what was sent" with token cost) and apps can
be excluded. This is the PRD's original principle 3 ("show what you sent") + 6 ("local
first when possible").

**Fully local is a supported path, not the headline:** point the OpenAI-compatible
adapter at LM Studio or Ollama and nothing leaves the Mac at all. We say so in Settings
and the docs, honestly ("weaker at Do"), and never claim it as the default experience.

**Dropped for good:** "never a byte to the cloud", "not ChatGPT, not Claude", the
no-BYOK principle, the 16 GB gate, the model download.

## Architecture

One provider-neutral layer; adapters underneath. No OpenAI-compatible shim for
Anthropic — two native adapters.

```
AIProvider (protocol)                    Handle/AI/AIProvider.swift
 ├─ AnthropicProvider   Messages API      Handle/AI/AnthropicProvider.swift
 └─ OpenAIProvider      Chat Completions  Handle/AI/OpenAIProvider.swift
                        (+ custom base URL → LM Studio / Ollama / OpenRouter)
```

**Neutral types** (Handle-owned, mapped by each adapter):
- `AIMessage` — role `system | user | assistant | tool`; parts `.text`, `.image(Data, mime)`,
  `.toolCall(id, name, argumentsJSON)`, `.toolResult(id, text)`.
- `AIToolSpec` — `name`, `description`, `inputSchema` (JSON Schema object).
- `AIStreamEvent` — `.textDelta(String)`, `.toolCall(id, name, argumentsJSON)`,
  `.done(stopReason)`, `.usage(in, out)`.
- `AIProvider.stream(messages:tools:model:) -> AsyncThrowingStream<AIStreamEvent, Error>`
  (same `Task` + `onTermination { cancel }` pattern as `LocalEngine.generateStream`).

**Transport:** raw `URLSession` + SSE parsing (no official Swift SDK for either vendor;
first HTTP code in the app — keep it in `Handle/AI/SSE.swift`, ~80 lines). Errors as
`NSError` with `NSLocalizedDescriptionKey`, matching `MCPService`. Map 401 → "key
rejected", 429/5xx → retry with backoff (3 tries), offline → plain "no connection".
Never log request bodies (they contain screenshots) — `AuditLog` records tool calls only.

**Anthropic adapter specifics** (per current API): `POST /v1/messages`, header
`anthropic-version`, `x-api-key`; images as base64 content blocks; tools with
`strict: true` (needs `additionalProperties:false` + `required` in every schema);
`thinking: {type:"adaptive"}`; no assistant prefill; parse `stop_reason` before content
and surface `refusal`. Default model `claude-sonnet-5`; `claude-opus-5` selectable.
**OpenAI adapter specifics:** Chat Completions with `tools`, `stream:true`, image
parts as data URLs. Chat Completions (not Responses) because it is the shape every
OpenAI-compatible server implements — that is what makes the custom base URL field
work and quietly gives power users their local option back (LM Studio / Ollama) without
Handle maintaining MLX. Model list fetched from `/v1/models`, editable text fallback.
**Capability flags** on the provider (`supportsVision`, `supportsTools`) so a
tool-less local endpoint degrades to explain-only instead of failing mid-loop.

**Usage and cost (decided: show it).** Both adapters emit `.usage(in, out)` from
the provider's usage fields (Anthropic: `usage` on `message_delta`; OpenAI: the final
chunk when `stream_options.include_usage` is set). A small in-app price table keyed by
model id turns tokens into an estimate; unknown models (custom endpoints, new ids) show
tokens only, never a made-up price. Starting values for Anthropic (API list price,
verify at implementation): `claude-sonnet-5` $2 / $10 per MTok in / out,
`claude-opus-5` $5 / $25, `claude-haiku-4-5` $1 / $5. OpenAI prices: fill from the
OpenAI pricing page at implementation time — don't guess. Shown per turn in "what was
sent" and as a running session total in Settings → AI. Local endpoints show "$0 · local".

## What changes in the agent loop (`HandleApp.swift`)

1. **Native tool use replaces JSON scraping.** `runToolLoop` Path 2 (L924-1015) sends
   `ToolRegistry` specs as real tools; a `.toolCall` event replaces `parseToolCall` /
   `jsonObjectCandidates` / `parseFunctionCall` (L3051-3157). Keep the parser only for
   the OpenAI-compatible no-tools fallback. Tool results go back as `.toolResult`
   parts, not `"[Tool result for X]:"` text (L1102). Confirm-gated tools keep
   `awaitConfirmation` exactly as is.
2. **Point / click stay index-select.** `pointAtToolInstruction` becomes a
   `point_at{index:int}` tool over the same numbered AX list. Cloud models can emit
   coordinates, but index-select is still more reliable and keeps the live-frame re-read.
3. **A real system prompt.** `handleIdentity` (L1025-1037) + `actionToolInstruction`
   prose (L1108-1132) + context preamble move to `role: system`. Memory stays last
   in the user turn. Delete the "fold into user prompt" workaround and the matching note in the working notes.
4. **Identity copy.** Rewrite L1025-1037: Handle is local *software* using the user's
   own model account; drop "Not ChatGPT, not Claude". Flip the self-test at L2697.
5. **`askModel` one-shots** (recipe match/fill, MCP select/fill, schedule, trigger,
   title) route through the same provider; `matchRecipe`/`fillParams` should become
   tool calls too (`select_recipe{index}`, `fill{...}`) — removes four more scrapers.
6. **`streamOneTurn`** keeps its `display:false` buffering only for the fallback path;
   with native tools nothing JSON-shaped reaches the transcript anyway.
7. **Multi-image history** becomes possible (only the last user image is sent today,
   L1050). Keep last-image-only for cost; revisit.
8. Remove `LocalEngine.downscaledImage` (second cap is a no-op after
   `ImagePreparation` 1280). Keep 1280.

## Keys, settings, onboarding

- **Keychain:** generalise `MCPKeychain` (`MCPService.swift:178-249`) into
  `SecretStore(service:)`; providers use `com.dimarussu.Handle.providers`, keys
  `anthropic`, `openai`. Keys never in UserDefaults, never logged.
- **UserDefaults:** `handle.ai.provider` (`anthropic|openai`, **unset until the user
  picks — there is no default provider**), `handle.ai.model`,
  `handle.ai.openai.baseURL` (optional), `handle.see.excludedBundleIDs`,
  `handle.see.askBeforeSend` (bool).
- **Settings → new "AI" section** at the top of `SettingsBody` (`SettingsView.swift:81`):
  provider picker · key field (masked, paste, "Test" runs a 5-token request and shows
  the model name back) · model picker · advanced: custom base URL (OpenAI only) ·
  link to the provider's key page.
- **Onboarding** (`OnboardingView.swift`): step 2 `ModelStep` → `ConnectStep`: two
  equal cards (Anthropic, OpenAI), nothing preselected, plus a small "or a local
  OpenAI-compatible server" link that reveals the base-URL field. Pick → paste key →
  Test → continue. "Skip" allowed (Handle then opens Settings on first turn). If both
  keys are saved later, the Settings picker is the single source of truth; the app
  never switches provider on its own. Drop the ≥16 GB gate (`Onboarding.hardwareOK`, L15-17); keep Apple
  Silicon soft-note for Whisper. Rewrite L212, L244, L248-250, L352. Whisper download
  stays on first talk. Fix stale hotkey tip at L277.
- **No-key state:** `runToolLoop` short-circuits with a bubble "Connect an AI in
  Settings" instead of erroring.

## "See" consent redesign (required before ship)

`PRODUCT.md` says ambient capture is only acceptable because nothing leaves. With a
provider it must be *visible and controllable*:
1. **Capture indicator** in the notch every time `captureCurrentScreen` (L409) fires
   and the image is attached to a request — a brief eye/camera glyph, not a modal.
2. **"What was sent"** — keep the last N request summaries (provider, model, text,
   thumbnail of the image, byte size, tokens in/out, estimated cost) in memory only;
   a Settings → Activity row opens it. This is PRD principle 3 ("show what you sent").
3. **Excluded apps** — bundle-ID list in Settings; when the frontmost app is
   excluded, `promptReferencesScreen` still runs but the screenshot is *not* attached
   and the reply says so. Ship with suggested defaults (1Password, Bitwarden, banking
   apps found on the machine) unchecked, not silently on.
4. **Ask-before-send toggle** — for cautious users: a one-tap confirm before any
   screenshot leaves. Off by default.
5. Voice audio never leaves (still true, still say it).

## Remove

- `LocalEngine.swift`, `OnboardingDownload`, warm-up at `HandleApp.swift:86`.
- SPM: `mlx-swift-examples` and its three products (`project.pbxproj` L403-405,
  L439-451) plus transitive mlx-swift / swift-transformers / swift-jinja. WhisperKit,
  KeyboardShortcuts, MarkdownUI, MCP stay.
- `LocalAITest/` (MLX eval CLI) — delete or archive to a branch.
- `ModelStorage` stays (Whisper download root only); Storage settings copy updated.
- `AboutView` acknowledgements: drop MLX Swift, MLX Swift Examples, swift-jinja; keep
  swift-transformers only if WhisperKit still pulls it.
- `Action.swift:76-148` `Prompts.system` (dead old cloud prompt) — delete, don't revive.

## Docs & strings to rewrite (all currently promise "never a byte")

`PRODUCT.md` (one-sentence, §See, Private AI architecture, Principle 2, competitor
table, Out of scope), the working notes' header and four later lines, `AUTOMATIONS.md` L4/13/25/154/
187/213, in-app: `HandleApp.swift:1025-1037`, `OnboardingView.swift:212/244/352`,
`SettingsView.swift:521` (memory copy is still true — keep), `ImagePreparation.swift`
doc comment (now correct again). Whisper / TTS / memory / audit strings stay true.

## Phases (each shippable behind a flag)

| # | Scope | Files |
|---|---|---|
| 0 | ✅ `AIProvider` + neutral types + SSE + `AnthropicProvider`; `askModel` and `streamOneTurn` switch on a debug flag `handle.ai.enabled` | `Handle/AI/*`, `HandleApp.swift` |
| 1 | ✅ Native tools in `runToolLoop`, system prompt, point/click as tools, identity rewrite, prompt caching, self-tests | `HandleApp.swift`, `Handle/AI/AgentPrompting.swift` |
| 2 | ✅ SecretStore, Settings AI section, onboarding ConnectStep, no-key state, 16 GB gate removed | `Handle/AI/AIConfig.swift`, `AIConnectViews.swift`, `SettingsView.swift`, `OnboardingView.swift` |
| 3 | ✅ See consent: notch eye + bubble captions, "what was sent" (thumbnails, tokens, cost), excluded apps, ask-before-send, session cost total | `Handle/AI/SeeSettings.swift`, `SentLog.swift`, `HandleApp.swift`, `NotchRootView.swift`, `SettingsView.swift` |
| 4 | ✅ `OpenAIProvider` + custom base URL + capability flags + no-tools/no-vision fallbacks + the honest "fully local" Settings copy + fake server for tests | `Handle/AI/OpenAIProvider.swift`, `SettingsView.swift`, `tools/fake_openai_server.py` |
| 5 | ✅ Rip out MLX, LocalAITest, docs and strings; recipes/MCP/schedule/trigger one-shots → native tools | pbxproj, `PRODUCT.md`, the working notes, `AUTOMATIONS.md`, `HandleApp.swift` |

Order matters: 0→1 proves the agent gain before any UI work; 3 before any external
tester sees ambient capture; 4 after the abstraction has survived one real provider.

## Status

- **Phase 0 — DONE 2026-09-19.** BUILD SUCCEEDED on Xcode 27 / Swift 6.4, 0 warnings in
  `Handle/AI`, `__selftest__` 306/306 (+9 for SSE + the Anthropic decoder). Live API turn
  still unverified — no key on the dev Mac yet. Files: `Handle/AI/AIProvider.swift`,
  `SSE.swift`, `AnthropicProvider.swift`, `SecretStore.swift`, `AIConfig.swift`,
  `CloudEngine.swift`; switch points in `HandleApp.swift` (`streamOneTurn`, `askModel`,
  plan probe, warm-up). Dev probe: `tools/cloudprobe.sh`.
- **Phase 1 — DONE 2026-09-19, proven live.** Native tools in `runToolLoop`, real system
  role, `point_at` as a native tool, provider-aware identity, prompt caching (system + tool
  schemas; ~7.5k tokens cached, 200–300 uncached per action step). 320/320 self-tests.
  Identity eval and a two-step calendar tool loop verified in the app. changelog has the numbers.
- **Phase 2 — DONE 2026-09-19, verified.** Settings → AI (picker · key · Test · model ·
  session cost · honest footer), onboarding `ConnectStep` (nothing preselected, Skip
  allowed), no-key state in the loop, 16 GB gate removed, `MCPKeychain` folded onto
  `SecretStore`. 329/329 self-tests; screens rendered via `__uishot__`.
- **Phase 3 — DONE 2026-09-19, verified.** Exclusion at capture time, consent + caption +
  notch eye at send time, "What was sent" (memory-only, thumbnails, cost) and "Screen"
  sections in Settings. 336/336 self-tests; exclusion proven live via `__seetest__`.
  Still to look at: the closed-pill eye glyph and the ask-before-send card.
- **Phase 4 — DONE 2026-09-19, verified against a fake OpenAI-compatible server**
  (`tools/fake_openai_server.py`; no OpenAI key on the dev Mac). `OpenAIProvider`, custom
  base URL, key-optional local endpoints, tools/vision capability toggles with the fold +
  scrape fallback, OpenAI card enabled. 351/351 self-tests. **My call (2026-09-19):
  no OpenAI key for now — Claude is the provider in use; a live check against
  api.openai.com waits until someone has a key.**
- **Phase 5 — DONE 2026-09-19. Migration complete.** MLX and every trace of the on-device
  model removed (clean build, no Metal, 32 MB bundle), `PRODUCT.md`/the working notes/`AUTOMATIONS.md`
  rewritten to "local software, your model", recipe/MCP/schedule/trigger one-shots are
  native tool calls with the text path as fallback. 355/355 self-tests; one-shots proven
  live. Open: a live check of the OpenAI adapter against api.openai.com (no key yet,
  deferred), and a look at the notch eye + ask-before-send card.

### Using it (phase 2+)

Settings → **AI** (first section): pick a provider — nothing is preselected — paste the
key, **Save & test** (a 16-token round trip; shows "Connected — <model> answered in N s"),
choose a model. Onboarding has the same form as its third step (two equal cards; OpenAI's
is disabled until phase 4; "Skip for now" is allowed). Keys saved from the app are written
by the app, so no Keychain prompt. With nothing connected, any turn answers with
"Connect an AI first — open Settings → AI…" instead of erroring. `handle.ai.provider` =
`anthropic` | `openai` or unset (no default). The on-device model and its `local` kind
were removed in phase 5; a local model now means an OpenAI-compatible server.

**OpenAI / compatible servers:** pick OpenAI, paste a key (or none for a local server),
open "Custom server" and set the base URL — LM Studio `http://localhost:1234/v1`, Ollama
`http://localhost:11434/v1`, OpenRouter `https://openrouter.ai/api/v1` — then "Fetch
models…" and pick one. Two toggles say what the model there can do: tool calls (off →
Handle folds the tool instructions into the prompt and reads the call back from the
text, like the old on-device path) and images (off → no screenshots are sent, and the
bubble says so). A local server means nothing leaves the Mac: the identity says so, the
cost line reads "$0 · local". Test the adapter without the app:
`tools/cloudprobe.sh --provider openai --base http://localhost:1234/v1 --model <id> "hi"`,
or against the bundled fake: `python3 tools/fake_openai_server.py 8765 &` then `--base
http://127.0.0.1:8765/v1`.

From the CLI: `defaults write com.dimarussu.Handle handle.ai.provider anthropic` +
`security add-generic-password -U -s com.dimarussu.Handle.providers -a anthropic -w '…'`
(that CLI-made item triggers a one-time "Always Allow" Keychain dialog — keys saved from
Settings don't). Without the app: `tools/cloudprobe.sh "say hi in three words"`
(`--image PATH` for a See turn, `--tools` to watch tool-call streaming). Log lines:
`cloud turn: anthropic/<model> in=… out=… cache(r=… w=…) tools=… stop=… <s>`.
If a `defaults write` "doesn't take", see the working notes' gotchas (stale sandbox container).

## Decisions (2026-09-19)

- **No default provider.** The user chooses; nothing is preselected in onboarding, and
  the app never switches on its own. Unset provider = the no-key state.
- **Show token cost.** Per turn in "what was sent", running total in Settings → AI,
  tokens-only when the price is unknown, "$0 · local" for local endpoints.
- **Keep the local story where it stays true.** On-device processing is enumerated
  honestly (capture, OCR, AX, voice, memory, storage); the fully-local endpoint path is
  supported and documented, but "your model, your key" is the headline, not "offline".
