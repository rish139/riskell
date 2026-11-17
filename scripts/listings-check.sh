#!/usr/bin/env bash
# Checks listings/*.json against the app: every built-in atom has a listing and the other way round, every source file exists, and the
# fields the schema requires are there. Needs a release build (swift build -c release). Exit 1 on a finding.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"; cd "$root"
bin=.build/release/riskell
[ -x "$bin" ] || { echo "listings-check: build first (swift build -c release)"; exit 1; }
atoms_json="$("$bin" --list-atoms | tail -n 1)"      # the last line: the app may print a line about installed packages first
ATOMS="$atoms_json" python3 -I - <<'PY'
import json, os, glob, sys
atoms = {a["id"]: a for a in json.loads(os.environ["ATOMS"])}
need = ["id", "name", "kind", "builtin", "summary", "license", "repository", "source", "home", "homeNote"]
bad = 0
def fail(m):
    global bad; print("listings-check: " + m); bad += 1
files = {os.path.basename(f)[:-5]: json.load(open(f)) for f in glob.glob("listings/*.json")}
lock = {e["id"] for e in json.load(open("extensions.lock.json"))}
for id in atoms:
    if id not in files: fail("no listing for built-in atom %s (listings/%s.json)" % (id, id))
for id, d in files.items():
    if files[id].get("home") == "package":      # moved out: its package is installed by the lock, and is no longer in the app's own list
        pk = {x for x in (src.split("/")[1] for src in files[id].get("source", []) if src.startswith("Packages/"))}
        if id not in lock and not (pk & lock): fail("listings/%s.json: home is package but no package of its source is in extensions.lock.json" % id)
        if id in atoms: fail("listings/%s.json: home is package but the app still has a built-in %s" % (id, id))
        atoms[id] = {"name": files[id].get("name")}
    elif id not in atoms: fail("listings/%s.json is not a built-in atom" % id); continue
    for k in need:
        if k not in d: fail("listings/%s.json: \"%s\" is missing" % (id, k))
    if d.get("id") != id: fail("listings/%s.json: id is %r" % (id, d.get("id")))
    if d.get("name") != atoms[id]["name"]: fail("listings/%s.json: name %r differs from the app's %r" % (id, d.get("name"), atoms[id]["name"]))
    if d.get("home") not in ("app", "kit", "package"): fail("listings/%s.json: home must be app, kit or package" % id)
    if len(d.get("summary", "")) > 160: fail("listings/%s.json: summary over 160 characters" % id)
    for s in d.get("source", []):
        if not os.path.exists(s): fail("listings/%s.json: source %s does not exist" % (id, s))
if not bad: print("listings-check: %d listings match the app" % len(files))
sys.exit(1 if bad else 0)
PY
