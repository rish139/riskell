#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title AeroSpace: check the two key sets
# @raycast.mode fullOutput

# Optional parameters:
# @raycast.packageName AeroSpace
# @raycast.icon ⌨️
# @raycast.description Compares the main and riskell binding modes of the loaded AeroSpace config. AeroSpace cannot share bindings between modes, so a key added to one and not the other is dead in the other. The keys that act through riskell differ on purpose.

# keys that only the plain main mode has, on purpose (walking the workspaces without riskell)
FALLBACK_ONLY="ctrl-left ctrl-right"

AS=$(command -v aerospace || echo /opt/homebrew/bin/aerospace)
# AEROSPACE_MODES_JSON names a file to read instead of asking AeroSpace (for trying the check)
if [ -n "$AEROSPACE_MODES_JSON" ]; then cat "$AEROSPACE_MODES_JSON"; else "$AS" config --get mode --json; fi |
FALLBACK_ONLY="$FALLBACK_ONLY" /usr/bin/python3 -c '
import json, os, sys
modes = json.load(sys.stdin)
main, rk = modes.get("main", {}).get("binding", {}), modes.get("riskell", {}).get("binding", {})
if not rk:
    print("There is no riskell mode in the config: riskell has nothing to enter and the plain keys are all there is."); sys.exit(1)
fallback = set(os.environ.get("FALLBACK_ONLY", "").split())
only_main = sorted(k for k in main if k not in rk and k not in fallback)
only_rk = sorted(k for k in rk if k not in main)
through_riskell = sorted(k for k in main if k in rk and main[k] != rk[k] and rk[k] == "true")
other_diff = sorted(k for k in main if k in rk and main[k] != rk[k] and rk[k] != "true")
bad = False
if only_main:
    bad = True; print("In main but not in riskell (dead while riskell runs, which is nearly always):"); [print("   ", k, "=", main[k]) for k in only_main]
if only_rk:
    bad = True; print("In riskell but not in main (dead when riskell is off):"); [print("   ", k, "=", rk[k]) for k in only_rk]
if other_diff:
    bad = True; print("Different in the two modes, and not a key that acts through riskell:"); [print("   ", k, ": main", main[k], "| riskell", rk[k]) for k in other_diff]
print("Keys that act through riskell (bound to true there, plain in main): " + (", ".join(through_riskell) or "none"))
print("Keys of the plain mode only, on purpose: " + (", ".join(sorted(fallback & set(main))) or "none"))
print(("The two key sets are in step." if not bad else "The two key sets are NOT in step.") + " (main %d keys, riskell %d keys)" % (len(main), len(rk)))
sys.exit(1 if bad else 0)
'
