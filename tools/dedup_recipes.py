#!/usr/bin/env python3
"""
Drop newly-mined recipes that functionally duplicate the EXISTING library
(built-ins + live file recipes). Duplicates pollute retrieval — the prefilter
surfaces both and the model coin-flips between identical automations (the
dup-of-builtin lesson from the raycast pass, now at 200+ scale).

Similarity = Jaccard over normalized title+keyword tokens. ≥ THRESHOLD drops
the NEW file (the incumbent stays canonical — it's already retrieval-tuned).
Every drop is printed with its match so the pass stays reviewable.

Usage: dedup_recipes.py <new-dir> <existing-recipes-dir>
"""
import os, re, sys

THRESHOLD = 0.5

STOP = {"the", "a", "an", "to", "with", "of", "and", "or", "in", "on", "for", "your",
        "my", "from", "is", "are", "be", "this", "that", "it", "as", "by", "at", "set",
        "into", "current", "given", "app", "macos", "system", "new", "create", "get"}

# Built-ins live in Recipe.swift, not as files — their retrieval identity here.
BUILTINS = {
    "quit-apps": "quit applications close apps",
    "open-folder": "open a folder finder",
    "music-control": "control music playback play pause skip song",
    "set-volume": "set system volume sound level",
    "new-note": "create a note notes",
    "empty-trash": "empty the trash bin",
    "web-search": "search the web google",
    "dark-mode": "toggle dark mode appearance light",
}


# Functional duplicates the Jaccard pass can't see (keyword-rich KB entries
# dilute the overlap): reviewed by hand, the incumbent stays canonical.
MANUAL_DUPS = {
    "am-system-volume-control",          # set-volume (built-in)
    "am-system-volume-control-manager",  # set-volume (built-in)
    "am-music-playback-controls",        # music-control (built-in)
    "am-music-current-track-info",       # rc-apple-music-current-track (retrieval-tuned)
}


def tokens(md_or_text, is_file):
    if is_file:
        title = keywords = ""
        for line in md_or_text.splitlines():
            if line.startswith("title:"):
                title = line[6:]
            elif line.startswith("keywords:"):
                keywords = line[9:]
        text = title + " " + keywords
    else:
        text = md_or_text
    return {w for w in re.split(r"[^a-z0-9]+", text.lower()) if len(w) >= 3 and w not in STOP}


def main():
    newdir, existing = sys.argv[1], sys.argv[2]
    incumbents = [(rid, tokens(t, False)) for rid, t in BUILTINS.items()]
    for f in sorted(os.listdir(existing)):
        if f.endswith(".md"):
            incumbents.append((f[:-3], tokens(open(os.path.join(existing, f)).read(), True)))

    kept, dropped = 0, 0
    for f in sorted(os.listdir(newdir)):
        if not f.endswith(".md"):
            continue
        path = os.path.join(newdir, f)
        if f[:-3] in MANUAL_DUPS:
            print(f"drop {f[:-3]}  (manual dup list)")
            os.unlink(path)
            dropped += 1
            continue
        toks = tokens(open(path).read(), True)
        if not toks:
            continue
        best, best_j = None, 0.0
        for rid, inc in incumbents:
            if not inc:
                continue
            j = len(toks & inc) / len(toks | inc)
            if j > best_j:
                best, best_j = rid, j
        if best_j >= THRESHOLD:
            print(f"drop {f[:-3]}  (≈ {best}, j={best_j:.2f})")
            os.unlink(path)
            dropped += 1
        else:
            kept += 1
    print(f"kept {kept}, dropped {dropped} duplicates")


if __name__ == "__main__":
    main()
