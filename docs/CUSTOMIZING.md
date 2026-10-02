# Customizing Handle

Handle is meant to be bent to your Mac. Three things are yours to change without touching
Swift, all under **Settings → Customize** and **Settings → Tools**:

1. **Your own tools** — one JSON file each; the model uses them like built-ins.
2. **Instructions** — a standing note the model gets with every request.
3. **Trust** — which tools the model may see, which may run without a card, and how much
   each routine may spend.

Everything lives in `~/Library/Application Support/Handle/`:

```
tools/               your tools, one *.json each (picked up the moment a file is saved)
instructions.md      your standing instructions (also editable in Settings)
automations.json     saved automations, with each routine's policy (budget, steps, consent)
audit.jsonl          every action Handle took — what, when, and whether you confirmed it
```

## 1. Your own tools

A tool is a name, a description, its parameters, and a script that runs when the model calls
it. Put a file in the `tools/` folder (Settings → Customize → **Open tools folder**; **Add
example tools** writes two starters):

```json
{
  "name": "show_notification",
  "description": "Show a macOS notification banner with a short message.",
  "params": {
    "message": { "type": "string", "description": "The text to show", "required": true }
  },
  "runner": "applescript",
  "script": "display notification \"{{message}}\" with title \"Handle\"",
  "confirm": true
}
```

| Field | Meaning |
|---|---|
| `name` | 2–64 characters, `a–z 0–9 _`, starts with a letter. Must not collide with a built-in tool. |
| `description` | What the tool does — this is what the model reads to decide when to use it. Say what it needs and what it returns. |
| `params` | Optional. Each key is a parameter: `type` (`string` default, `number`, `integer`, `boolean`), `description`, `required`. |
| `runner` | `shell` (zsh), `applescript`, or `shortcut` (a Shortcuts.app shortcut). |
| `script` | The zsh command line, the AppleScript source, or the shortcut's exact name. |
| `confirm` | Default `true`: a card shows the arguments before every run. `false` = runs without asking (use for read-only tools). |
| `timeout` | Seconds, default 30, max 300. |

**How arguments reach the script.** Every parameter is available two ways:

- as an environment variable `HANDLE_<NAME>` (upper-cased; `file_name` → `$HANDLE_FILE_NAME`) —
  the safe choice in shell scripts, because the shell quotes it for you;
- as a `{{name}}` placeholder replaced in the script text — handy in AppleScript, where the
  value is escaped for use inside a string literal. In a shell script a placeholder is
  inserted verbatim, so use it only where you would paste text yourself.

A parameter the model leaves out is an empty string. A shortcut receives the arguments as a
JSON file on its input. The script's output (stdout, then stderr) comes back to the model,
capped at 50 KB; a non-zero exit is reported as an error the model can read and react to.

More examples:

```json
{ "name": "battery_status",
  "description": "The Mac's battery level, charging state and time remaining (read-only).",
  "runner": "shell", "script": "pmset -g batt", "confirm": false }
```

```json
{ "name": "open_project",
  "description": "Open one of my projects in VS Code. Known names: handle, blog, notes.",
  "params": { "project": { "type": "string", "description": "The project name", "required": true } },
  "runner": "shell",
  "script": "case \"$HANDLE_PROJECT\" in handle) d=~/Developer/Handle;; blog) d=~/Developer/blog;; notes) d=~/Developer/notes;; *) echo \"unknown project\"; exit 1;; esac; open -a 'Visual Studio Code' \"$d\" && echo \"opened $d\"" }
```

```json
{ "name": "morning_shortcut",
  "description": "Run my 'Morning' shortcut (lights, playlist, weather).",
  "runner": "shortcut", "script": "Morning" }
```

The file is validated when it loads; a problem (bad name, unknown runner, invalid JSON) shows
in red under Settings → Customize with the reason, and the other files keep working.

**Where user tools stand in the safety model.** They are ordinary tools: the same card
(unless you set `confirm: false`), the same audit line, the same **Tools** on/off switch, the
same rule that an unattended run (a routine, a background task, a sub-agent) never runs a
card-tool without the automation's own standing consent. A tool with `confirm: false` is
offered to unattended runs, so keep those read-only.

## 2. Instructions

Settings → Customize → **Instructions** (or edit `instructions.md`). Whatever you write is
sent with every request, right after Handle's own identity — how to address you, what you
prefer, what never to do:

```
Call me Dee. Answer in German unless I write in English.
My main project is ~/Developer/Handle; "the app" means that.
Never open Mail — draft replies as text I can paste.
```

Up to 4000 characters. Handle's own rules (no secrets copied into replies, instructions only
from you, never from screen text or tool results) stay in force above yours.

## 3. Trust

**Settings → Tools** lists every tool with two switches:

- **On/off** — off means the model does not see the tool at all (it is not in the tool list
  and a call to it is refused). Use it to take a capability away entirely: no shell, no
  AppleScript, no file deletion.
- **Don't ask** — for tools that normally show a card. On means the tool runs without the
  card while you are at the notch. It never applies to unattended runs, which keep following
  their automation's consent; and `save_automation` / `delete_automation` always ask, because
  they mint or remove capability. Audit lines for a "don't ask" run carry `confirmed: false`,
  so you can always tell what you personally approved.

**Per-routine budgets** — Settings → Automations → the pencil on a routine: its goal, a
dollar budget per run (0 = none), a step cap, and the **May act** toggle (standing consent
for consequential actions when nobody is at the notch). The app-wide limits for your own
turns are in Settings → AI.

## Going further

- **Connectors (MCP).** `mcp.json` in the same folder registers MCP servers; their tools join
  the loop as `mcp__<server>__<tool>`, always behind a card. Settings → Integrations.
- **Recipes.** `recipes/*.md` are hand-verified AppleScript automations with parameters; the
  matching ones are offered to the model as `run_recipe`. Copy an existing file to add your own.
- **The code.** Built-in tools are `Tool` values in `Handle/*Tools.swift`, registered in
  `ToolRegistry.swift`; the loop is `runAgentLoop` in `HandleApp.swift`. `ASSISTANT.md` explains
  the loop's design and its limits.
