#!/usr/bin/env python3
"""
Compile-validate recipe .md files: substitute dummy params exactly the way
Akari's Recipe.resolve does (raw substitution — string templates carry their
own quotes), then `osacompile` the body. Compilation only, never execution.
Failing files are MOVED to <dir>/_invalid/ with the compiler error appended
as a trailing comment, so the pipeline stays inspectable.

Usage: validate_recipes.py <recipes-dir>
"""
import os, re, subprocess, sys, tempfile

DUMMY = {"int": "1", "string": "x", "stringList": '"a"'}


def parse(md):
    lines = md.splitlines()
    close = lines.index("---", 1)
    params = []
    for l in lines[1:close]:
        if l.startswith("param:"):
            parts = [p.strip() for p in l[6:].split("|")]
            name = parts[0]
            ptype = parts[1] if len(parts) > 1 else "string"
            params.append((name, ptype))
    return params, "\n".join(lines[close + 1:])


def dummy_for(ptype):
    if ptype.startswith("oneOf("):
        return ptype[6:-1].split(",")[0].strip()
    return DUMMY.get(ptype, "x")


def main():
    d = sys.argv[1]
    invalid_dir = os.path.join(d, "_invalid")
    ok, bad = 0, 0
    for f in sorted(os.listdir(d)):
        if not f.endswith(".md"):
            continue
        path = os.path.join(d, f)
        md = open(path).read()
        try:
            params, body = parse(md)
        except ValueError:
            params, body = [], ""
        for name, ptype in params:
            body = body.replace("${%s}" % name, dummy_for(ptype))
        with tempfile.NamedTemporaryFile(suffix=".scpt", delete=False) as out:
            r = subprocess.run(["osacompile", "-o", out.name, "-e", body],
                               capture_output=True, text=True, timeout=30)
        os.unlink(out.name)
        if r.returncode == 0:
            ok += 1
        else:
            bad += 1
            os.makedirs(invalid_dir, exist_ok=True)
            err = (r.stderr or "?").strip().splitlines()[0]
            open(os.path.join(invalid_dir, f), "w").write(md + f"\n-- OSACOMPILE: {err}\n")
            os.unlink(path)
    print(f"valid {ok}, invalid {bad} (moved to _invalid/)")


if __name__ == "__main__":
    main()
