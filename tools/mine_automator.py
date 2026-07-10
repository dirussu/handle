#!/usr/bin/env python3
"""
Mine steipete/macos-automator-mcp's knowledge_base into Akari recipe .md files
(the recipes-200+ pass; raycast/script-commands was the first source — see
mine_raycast.py for the target format documentation).

KB entry format: YAML frontmatter (title, id, description, keywords list,
language, `parameters: >` free-text "- name (required): prompt" lines, notes)
+ a markdown body with ```applescript fences. Placeholders in the code are
`--MCP_INPUT:name` or `${name}` — both become Akari's `${name}`.

Policy (quality over quantity, same as the raycast pass):
  - action categories only (04–13, minus 11_advanced) — 01/02/03 are tutorials
    and JXA, not user automations.
  - `language: applescript` only (Akari runs AppleScript, not JXA).
  - first ```applescript fence is the body; entries whose body defines only
    handlers (no top-level statements) are documentation, not recipes → skip.
  - self-consistency: every ${x} in the body gets a param — from the
    frontmatter `parameters:` block when declared, else SYNTHESIZED from the
    placeholder name (many KB entries use --MCP_INPUT: without declaring;
    "dirPath" → prompt "Dir path"). A declared param unused by the body is
    dropped silently (KB docs over-declare).
  - every emitted body must osacompile with dummy params (validated later by
    the shared validate step in curate).

Usage: mine_automator.py <macos-automator-mcp-repo> <output-dir>
"""
import os, re, sys, unicodedata

CATEGORIES = ("04_system", "05_files", "06_terminal", "07_browsers", "08_editors",
              "09_productivity", "10_creative", "12_network", "13_developer")

STOP = {"the", "a", "an", "to", "with", "of", "and", "or", "in", "on", "for", "your",
        "my", "from", "is", "are", "be", "this", "that", "it", "as", "by", "at",
        "into", "current", "given", "app", "macos", "script", "scripts", "using"}

INT_HINT = re.compile(r"\b(number|level|index|count|seconds|minutes|amount|0-100|1-\d+|pixels|percent|port)\b", re.I)


def slug(s):
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-zA-Z0-9]+", "-", s).strip("-").lower()


def parse_frontmatter(text):
    """Hand-rolled YAML-subset parse: scalars, quoted scalars, `- item` lists,
    and `key: >` folded blocks. Good enough for this KB's uniform frontmatter."""
    m = re.match(r"\A---\n(.*?)\n---\n(.*)\Z", text, re.S)
    if not m:
        return None, None
    fm_text, body = m.group(1), m.group(2)
    fm, key = {}, None
    lines = fm_text.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        km = re.match(r"^([A-Za-z_]+):\s*(.*)$", line)
        if km:
            key, val = km.group(1), km.group(2).strip()
            if val == ">" or val == "|" or val == "":
                block = []
                j = i + 1
                while j < len(lines) and (lines[j].startswith(" ") or lines[j].strip() == ""):
                    block.append(lines[j].strip())
                    j += 1
                # a list under the key?
                if any(b.startswith("- ") for b in block):
                    fm[key] = [b[2:].strip().strip('"').strip("'") for b in block if b.startswith("- ")]
                else:
                    fm[key] = "\n".join(b for b in block if b)
                i = j
                continue
            fm[key] = val.strip('"').strip("'")
        i += 1
    return fm, body


def first_applescript_fence(body):
    m = re.search(r"```applescript\n(.*?)```", body, re.S)
    return m.group(1).strip() if m else None


def parse_params(fm):
    """'- name (required): prompt' lines → [(name, required, prompt, type)]."""
    raw = fm.get("parameters", "")
    if isinstance(raw, list):
        raw = "\n".join(raw)
    out = []
    for m in re.finditer(r"-\s*`?([A-Za-z_][A-Za-z0-9_]*)`?\s*\((required|optional)[^)]*\)\s*:\s*([^\n]+)", raw):
        name, req, prompt = m.group(1), m.group(2) == "required", m.group(3).strip()
        ptype = "int" if INT_HINT.search(name + " " + prompt) else "string"
        out.append((name, req, prompt, ptype))
    return out


def keywords_for(fm, title):
    words = []
    kw = fm.get("keywords", [])
    if isinstance(kw, str):
        kw = [k.strip() for k in kw.split(",")]
    for k in kw:
        k = k.strip().lower()
        if k and k not in words and k not in STOP:
            words.append(k)
    for w in re.split(r"[^a-zA-Z0-9]+", title.lower()):
        if len(w) >= 3 and w not in STOP and w not in words:
            words.append(w)
    return ", ".join(words[:12])


def humanize(name):
    """'dirPath' / 'volume_level' → 'Dir path' / 'Volume level'."""
    words = re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", name).replace("_", " ").lower()
    return (words[:1].upper() + words[1:]).strip() or name


def only_handlers(script):
    """True when every top-level statement is a handler/property/use decl —
    documentation snippets, not runnable automations."""
    depth = 0
    for line in script.splitlines():
        s = line.strip()
        if not s or s.startswith("--") or s.startswith("#"):
            continue
        if depth == 0:
            if re.match(r"(on|to)\s+\w+", s):
                depth += 1
                continue
            if re.match(r"(property|use|global)\b", s):
                continue
            return False   # a real top-level statement
        if re.match(r"end\b", s):
            depth = max(0, depth - 1)
        elif re.match(r"(on|to)\s+\w+", s):
            depth += 1
    return True


def convert(path, repo_root):
    text = open(path, encoding="utf-8").read()
    fm, body = parse_frontmatter(text)
    if not fm or fm.get("language", "").lower() != "applescript":
        return None, "not-applescript"
    title = fm.get("title", "").strip()
    if not title or os.path.basename(path) == "_category_info.md":
        return None, "category-info"
    script = first_applescript_fence(body)
    if not script:
        return None, "no-fence"
    if only_handlers(script):
        return None, "handlers-only"

    # placeholders → ${name}; collect what the body actually uses
    script = re.sub(r'--MCP_INPUT:([A-Za-z_][A-Za-z0-9_]*)', r'${\1}', script)

    # `on run {a, b}` bodies REJECT argument-less execution (osascript: "{}
    # doesn't match the parameters" — smoke-tested), and Akari always runs
    # recipes argument-less. Rewrite the header to `set a to missing value`
    # assignments — the KB's own fallback branches (`if a is missing value
    # then set a to "${a}"`) then pick up the substituted values — and drop
    # the matching trailing `end run`.
    hm = re.match(r"\s*on run\s*\{([^}]*)\}\s*\n", script)
    if hm:
        names = [n.strip() for n in hm.group(1).split(",") if n.strip()]
        prelude = "\n".join(f"set {n} to missing value" for n in names)
        rest = script[hm.end():]
        idx = rest.rfind("end run")
        if idx >= 0:
            rest = rest[:idx] + rest[idx + len("end run"):]
        script = (prelude + "\n" + rest).strip()
    elif re.match(r"\s*on run argv\b", script):
        return None, "argv-handler"   # positional argv, nothing to map names to
    used = set(re.findall(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", script))
    declared = parse_params(fm)
    declared_names = {p[0] for p in declared}
    params = [p for p in declared if p[0] in used]
    for name in sorted(used - declared_names):
        prompt = humanize(name)
        ptype = "int" if INT_HINT.search(name + " " + prompt) else "string"
        params.append((name, True, prompt, ptype))

    rid = "am-" + slug(fm.get("id") or title)
    param_lines = []
    for name, req, prompt, ptype in params:
        prompt = prompt.replace("|", "/").strip()
        line = f"param: {name} | {ptype} | {prompt}"
        if not req:
            line += " | "        # optional → empty default (KB scripts self-default)
        param_lines.append(line)

    confirm = title if not params else f"{title} (${{{params[0][0]}}})"
    desc = (fm.get("description", "") or title).replace("\n", " ").strip()
    rel = os.path.relpath(path, repo_root)
    front = [
        "---",
        f"id: {rid}",
        f"title: {title}",
        f"source: {rel}",
        f"description: {desc}",
        f"keywords: {keywords_for(fm, title)}",
        f"confirm: {confirm}",
        *param_lines,
        "---",
    ]
    return rid, "\n".join(front) + "\n" + script + "\n"


def main():
    repo, outdir = sys.argv[1], sys.argv[2]
    os.makedirs(outdir, exist_ok=True)
    kept, skipped = 0, {}
    for cat in CATEGORIES:
        catdir = os.path.join(repo, "knowledge_base", cat)
        if not os.path.isdir(catdir):
            continue
        for root, _, files in os.walk(catdir):
            for f in sorted(files):
                if not f.endswith(".md") or f == "_category_info.md":
                    continue
                path = os.path.join(root, f)
                rid, result = convert(path, repo)
                if rid is None:
                    reason = result.split(":")[0]
                    skipped[reason] = skipped.get(reason, 0) + 1
                    continue
                open(os.path.join(outdir, rid + ".md"), "w").write(result)
                kept += 1
    print(f"kept {kept}; skipped: " + ", ".join(f"{k}×{v}" for k, v in sorted(skipped.items())))


if __name__ == "__main__":
    main()
