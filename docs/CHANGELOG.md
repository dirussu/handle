# Changelog

## 1.0.1 (2 October 2026)

- New app icon.

## 1.0 (2 October 2026)

First public release, with a downloadable build.

- Typing and key presses name the app they are meant for, and nothing is sent if a
  different app is in front.
- Your own tools: a JSON file per tool, backed by a shell command, AppleScript or a
  Shortcut. Standing instructions, per-tool on/off and "don't ask", and a budget and step
  cap per routine.
- Release builds, a universal app for Apple silicon and Intel, and a build check on every push.

## September 2026

- **A full assistant.** One agent loop serves chat turns, sub-agents, routines and
  background tasks. A policy sets the allowed tools, step cap, budget and consent for each run.
- **Hands and eyes.** Read a window's elements, click, type, press keys, scroll, and take a
  fresh look at the screen.
- **Recipes, connectors and the web as tools.** The loop decides when a verified recipe
  fits. MCP tools join as native tools, always behind a confirmation card. Pages can be fetched,
  and web search is available with Anthropic.
- **Bring your own key.** Anthropic and OpenAI-compatible providers replace the earlier
  on-device model. Nothing is preselected. Every send is visible with its cost, apps can be
  excluded from capture, and Handle can ask before sending a screenshot.
- **Safety pass.** Unattended runs are read-only unless an automation has standing consent,
  a running task can be stopped from Settings, and the audit log records whether a person
  confirmed each action.
- Spoken replies removed.

## July 2026

- MCP client for local servers, with secrets in the Keychain.
- Routines, and event triggers: a file appears, an app launches, Wi-Fi connects, a window
  title matches, a calendar event is near, the screen locks.
- The recipe library grew to about 300 verified automations.
- Onboarding, the chats list, a click-to-talk microphone, notch notifications, a motion
  system and a reorganised Settings page.
- Pointing by element index through Accessibility, and hold-to-talk voice with on-device
  transcription.
