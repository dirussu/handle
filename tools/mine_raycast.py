#!/usr/bin/env python3
"""
Mine raycast/script-commands (.applescript) into Akari recipe .md files.

Akari's recipe format (see Recipe.swift / RecipeFile.parse):
    ---
    id: <slug>
    title: <title>
    description: <text>
    keywords: a, b, c
    confirm: <template>
    param: name | type | prompt | default        (type: string|int|stringList|oneOf(a,b))
    ---
    <flat AppleScript body, ${param} placeholders>

Raycast format: a `#`-comment header block of `@raycast.*` directives, then AppleScript
whose args arrive as either `on run argv` + `item N of argv`, or `on run {named,...}`,
or no args at all. We rewrite arg references to quoted `${param}` placeholders — quoted
because Akari substitutes string params RAW (the quotes must live in the template).

Emits ONLY recipes that pass a self-consistency check (every ${x} has a param, every
param is used); everything else is skipped with a logged reason. Quality over quantity.

Usage: mine_raycast.py <script-commands-repo> <output-dir>
"""
import json, os, re, sys, unicodedata

STOP = {"the","a","an","to","with","of","and","or","in","on","for","your","my","from",
        "is","are","be","this","that","it","as","by","at","into","current","given","app"}

def slug(s, sep="-"):
    s = unicodedata.normalize("NFKD", s).encode("ascii","ignore").decode()
    s = re.sub(r"[^a-zA-Z0-9]+", sep, s).strip(sep).lower()
    return s

def snake(s):
    s = unicodedata.normalize("NFKD", s).encode("ascii","ignore").decode()
    s = re.sub(r"[^a-zA-Z0-9]+", "_", s).strip("_").lower()
    return s or "arg"

def read_text(path):
    """AppleScript files are UTF-8 or (legacy) MacRoman; the latter carries ≤ ≥ ¬ ≠
    as single bytes that utf-8 can't decode. Try utf-8, fall back to mac_roman."""
    data = open(path, "rb").read()
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return data.decode("mac_roman")

def parse_headers(text):
    """Return {directive: value} and ordered list of argument JSON dicts."""
    meta, args = {}, {}
    for line in text.splitlines():
        m = re.match(r"\s*#\s*@raycast\.(\w+)\s+(.*)$", line)
        if not m:
            continue
        key, val = m.group(1), m.group(2).strip()
        am = re.match(r"argument(\d+)$", key)
        if am:
            try:
                args[int(am.group(1))] = json.loads(val)
            except json.JSONDecodeError:
                args[int(am.group(1))] = None  # malformed → flagged later
        else:
            meta[key] = val
    ordered = [args[k] for k in sorted(args)]
    return meta, ordered

def strip_header(text):
    """Drop the leading shebang + #-comment block; return the AppleScript body."""
    lines = text.splitlines()
    i = 0
    while i < len(lines) and (lines[i].strip() == "" or lines[i].lstrip().startswith("#")):
        i += 1
    return "\n".join(lines[i:]).strip()

def keywords_for(meta, title):
    words = []
    for src in (title, meta.get("packageName","")):
        for w in re.split(r"[^a-zA-Z0-9]+", src.lower()):
            if len(w) >= 2 and w not in STOP and w not in words:
                words.append(w)
    return words[:8]

def param_type(argspec):
    """Map a raycast argument spec → (akari-type-string, prompt)."""
    if not isinstance(argspec, dict):
        return "string", "value"
    placeholder = argspec.get("placeholder") or argspec.get("name") or "value"
    if argspec.get("type") == "dropdown" and isinstance(argspec.get("data"), list):
        vals = [d.get("value", d.get("title","")) for d in argspec["data"] if isinstance(d, dict)]
        vals = [v for v in vals if v]
        if vals:
            return "oneOf(" + ",".join(vals) + ")", placeholder
    return "string", placeholder

def convert(text, stem):
    """Return (recipe_md, param_names) or (None, reason)."""
    meta, args = parse_headers(text)
    title = meta.get("title")
    if not title:
        return None, "no @raycast.title"
    if any(a is None for a in args):
        return None, "malformed argument JSON"
    body = strip_header(text)
    if not body:
        return None, "empty body"

    # Determine param names + rewrite the body's arg references to ${name}.
    params = []   # (name, type_str, prompt, default)
    run_named = re.search(r"^\s*on\s+run\s*\{([^}]*)\}", body, re.M)
    run_argv  = re.search(r"^\s*on\s+run\s+(\w+)\s*$", body, re.M)

    if run_named:
        names = [v.strip() for v in run_named.group(1).split(",") if v.strip()]
        if len(names) != len(args) and args:
            return None, f"run-signature/{len(names)} vs header-args/{len(args)} mismatch"
        # drop the destructuring signature; args are inlined as literals
        body = body[:run_named.start()] + "on run" + body[run_named.end():]
        for idx, var in enumerate(names):
            spec = args[idx] if idx < len(args) else {}
            t, prompt = param_type(spec)
            pname = snake(var)
            default = "" if (isinstance(spec, dict) and spec.get("optional")) else None
            params.append((pname, t, prompt, default))
            body = re.sub(r"\b" + re.escape(var) + r"\b", f'"${{{pname}}}"', body)
    elif args:
        # `on run argv` (or argv referenced): replace `item N of argv` per positional arg
        if run_argv:
            body = body[:run_argv.start()] + "on run" + body[run_argv.end():]
        for idx, spec in enumerate(args, start=1):
            t, prompt = param_type(spec)
            pname = snake(spec.get("placeholder","arg%d"%idx)) if isinstance(spec, dict) else "arg%d"%idx
            # avoid dup names
            base, n = pname, 2
            while pname in [p[0] for p in params]:
                pname = f"{base}_{n}"; n += 1
            default = "" if (isinstance(spec, dict) and spec.get("optional")) else None
            params.append((pname, t, prompt, default))
            pat = r"item\s+%d\s+of\s+argv" % idx
            body = re.sub(pat, f'"${{{pname}}}"', body)
    # else: no args → flat body, nothing to rewrite

    # Self-consistency: no leftover argv, every ${x} has a param, every param is used.
    if re.search(r"\bargv\b", body):
        return None, "unresolved argv reference after rewrite"
    used = set(re.findall(r"\$\{(\w+)\}", body))
    declared = {p[0] for p in params}
    if used - declared:
        return None, f"body uses undeclared placeholder(s): {sorted(used-declared)}"
    params = [p for p in params if p[0] in used]   # drop declared-but-unused

    # Assemble the .md
    kws = keywords_for(meta, title)
    desc = meta.get("description", title).replace("\n"," ").strip()
    out = ["---", f"id: {stem}", f"title: {title}"]
    if desc: out.append(f"description: {desc}")
    if kws:  out.append("keywords: " + ", ".join(kws))
    out.append(f"confirm: {title}")
    for name, t, prompt, default in params:
        line = f"param: {name} | {t} | {prompt}"
        if default is not None: line += f" | {default}"
        out.append(line)
    out.append("---")
    out.append(body)
    return "\n".join(out) + "\n", [p[0] for p in params]

def main():
    if len(sys.argv) != 3:
        print(__doc__); sys.exit(1)
    repo, outdir = sys.argv[1], sys.argv[2]
    os.makedirs(outdir, exist_ok=True)
    files = []
    for root,_,fs in os.walk(os.path.join(repo,"commands")):
        for f in fs:
            if f.endswith(".applescript"):
                files.append(os.path.join(root,f))
    files.sort()
    converted, skipped, seen = 0, [], {}
    for path in files:
        text = read_text(path)
        # `rc-` namespace so mined recipes never override hand-crafted built-ins by id.
        stem = "rc-" + slug(os.path.splitext(os.path.basename(path))[0])
        if stem in seen:
            seen[stem] += 1; stem = f"{stem}-{seen[stem]}"
        else:
            seen[stem] = 1
        md, info = convert(text, stem)
        if md is None:
            skipped.append((os.path.relpath(path, repo), info)); continue
        open(os.path.join(outdir, stem+".md"), "w", encoding="utf-8").write(md)
        converted += 1
    print(f"converted: {converted}/{len(files)}   skipped: {len(skipped)}")
    print("--- skip reasons (top) ---")
    from collections import Counter
    for reason, c in Counter(r for _,r in skipped).most_common(12):
        print(f"  {c:3}  {reason}")

if __name__ == "__main__":
    main()
