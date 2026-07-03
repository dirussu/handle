#!/usr/bin/env python3
"""
Curate mined recipe .md files into a vetted subset fit for Akari's live library.

Policy (PRODUCT.md #17 — recipes must be reliable on THIS Mac, not just valid):
  1. app-missing   — drop recipes that `tell application` / `open -a/-b` an app
                     that isn't installed here (checked against /Applications,
                     /System/Applications[/Utilities]; bundle ids via mdfind).
  2. source-drop   — drop hardware/remote-control scripts (e.g. Denon AVR) by
                     source path prefix.
  3. keystroke-param — drop recipes that `keystroke` a ${param} (typing user
                     text via System Events is slow + unreliable).
  4. dup-of-builtin — drop recipes that duplicate a built-in's exact function
                     (they'd pollute retrieval; the built-in stays canonical).
  5. overrides     — per-recipe keyword/prompt/default tuning for known
                     retrieval or fill edge cases.

Usage: curate_recipes.py <mined-dir> <vetted-out-dir>
"""
import os, re, subprocess, sys

STOCK = {"System Events", "Finder", "SystemUIServer", "Dock"}

# System processes that `tell process "X"` may target without an app bundle.
STOCK_PROCESSES = {"finder", "dock", "systemuiserver", "controlcenter", "controlcentre",
                   "notificationcenter", "spotlight", "systemsettings", "systempreferences",
                   "systemevents", "loginwindow", "windowserver"}

def norm(s):
    return re.sub(r"[^a-z0-9]", "", s.lower())

SOURCE_DROP_PREFIXES = ("commands/remote-control/",)

DUP_OF_BUILTIN = {
    "rc-create-note", "rc-create-note-2",   # built-in: new-note
    "rc-empty-trash",                       # built-in: empty-trash
    "rc-quit-application",                  # built-in: quit-apps
}

# Recipes for apps not on this Mac that hide behind URL schemes / killall, which the
# app-reference scan can't see. Manual until a real need to detect these patterns.
MANUAL_DROP = {"rc-meetingbar-create-meeting", "rc-meetingbar-join-meeting",
               "rc-tomighty-stop-pomodoro"}

# id → {"keywords": "...", "params": {old_name: (new_name, prompt, default|None)}}
OVERRIDES = {
    "rc-apple-music-volume-up": {
        "keywords": "apple music, music volume, louder, turn up the music, song volume, up",
    },
    "rc-apple-music-volume-down": {
        "keywords": "apple music, music volume, quieter, turn down the music, song volume, down",
    },
    "rc-apple-music-set-volume": {
        "keywords": "apple music, music volume, set music volume, song volume",
    },
    "rc-apple-music-current-track": {
        # the paraphrase space is "song/playing", not the title's "current track"
        "keywords": "song, now playing, what is playing, playing, current track, music",
    },
    "rc-safari-create-reading-list-item": {
        "params": {"link_use_open_for_current_safari_page":
                   ("link", "URL to add, or the word open for the current Safari page", "open")},
    },
}

def installed_app_names():
    names = set()
    for d in ("/Applications", "/Applications/Utilities",
              "/System/Applications", "/System/Applications/Utilities"):
        try:
            for f in os.listdir(d):
                if f.endswith(".app"):
                    names.add(f[:-4])
        except FileNotFoundError:
            pass
    return names

def bundle_id_installed(bid, cache={}):
    if bid not in cache:
        r = subprocess.run(["mdfind", f"kMDItemCFBundleIdentifier == '{bid}'"],
                           capture_output=True, text=True, timeout=10)
        cache[bid] = bool(r.stdout.strip())
    return cache[bid]

def required_apps(body):
    names = set(re.findall(r'tell application "([^"]+)"', body))
    names |= set(re.findall(r'open -a ["\']?([A-Za-z0-9 .-]+?)["\']?(?:\s|$)', body))
    ids = set(re.findall(r'tell application id "([^"]+)"', body))
    ids |= set(re.findall(r'open [^"\n]*-b\s+\\?"?([A-Za-z0-9.-]+)', body))
    # System Events UI scripting targets a PROCESS — the app must still be here.
    procs = set(re.findall(r'tell process "([^"]+)"', body))
    return names, ids, procs

def parse(md):
    lines = md.splitlines()
    close = lines.index("---", 1)
    fm = {"param": []}
    for l in lines[1:close]:
        if ":" not in l:
            continue
        k, v = l.split(":", 1)
        k, v = k.strip(), v.strip()
        if k == "param":
            fm["param"].append(v)
        else:
            fm[k] = v
    return fm, lines[1:close], "\n".join(lines[close+1:])

def apply_overrides(rid, fm_lines, body):
    ov = OVERRIDES.get(rid)
    if not ov:
        return fm_lines, body
    out = []
    for l in fm_lines:
        if "keywords" in ov and l.startswith("keywords:"):
            out.append("keywords: " + ov["keywords"]); continue
        if l.startswith("param:") and "params" in ov:
            parts = [p.strip() for p in l[6:].split("|")]
            if parts and parts[0] in ov["params"]:
                new, prompt, default = ov["params"][parts[0]]
                t = parts[1] if len(parts) > 1 else "string"
                line = f"param: {new} | {t} | {prompt}"
                if default is not None:
                    line += f" | {default}"
                out.append(line)
                body = body.replace("${%s}" % parts[0], "${%s}" % new)
                continue
        out.append(l)
    return out, body

def main():
    if len(sys.argv) != 3:
        print(__doc__); sys.exit(1)
    mined, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    installed = installed_app_names()
    kept, drops = 0, []
    for fn in sorted(os.listdir(mined)):
        if not fn.endswith(".md"):
            continue
        md = open(os.path.join(mined, fn), encoding="utf-8").read()
        fm, fm_lines, body = parse(md)
        rid = fm.get("id", fn[:-3])

        if rid in DUP_OF_BUILTIN:
            drops.append((rid, "dup-of-builtin")); continue
        if rid in MANUAL_DROP:
            drops.append((rid, "manual-drop (app not installed)")); continue
        src = fm.get("source", "")
        if any(src.startswith(p) for p in SOURCE_DROP_PREFIXES):
            drops.append((rid, f"source-drop ({src.split('/')[1]})")); continue
        if re.search(r'keystroke\s+"?\$\{', body):
            drops.append((rid, "keystroke-param")); continue
        names, ids, procs = required_apps(body)
        missing = {n for n in names if n not in installed and n not in STOCK}
        missing |= {i for i in ids if not bundle_id_installed(i)}
        installed_norm = {norm(n) for n in installed}
        missing |= {p for p in procs
                    if norm(p) not in STOCK_PROCESSES
                    and not any(norm(p) in a or a in norm(p) for a in installed_norm if a)}
        if missing:
            drops.append((rid, "app-missing: " + ", ".join(sorted(missing)))); continue

        fm_lines, body = apply_overrides(rid, fm_lines, body)
        open(os.path.join(out, fn), "w", encoding="utf-8").write(
            "---\n" + "\n".join(fm_lines) + "\n---\n" + body + ("" if body.endswith("\n") else "\n"))
        kept += 1

    print(f"kept: {kept}   dropped: {len(drops)}")
    from collections import Counter
    reasons = Counter(r.split(":")[0].split(" (")[0] for _, r in drops)
    for reason, c in reasons.most_common():
        print(f"  {c:3}  {reason}")
    print("--- dropped (app-missing detail) ---")
    for rid, r in drops:
        if r.startswith("app-missing"):
            print(f"    {rid}: {r[13:]}")

if __name__ == "__main__":
    main()
