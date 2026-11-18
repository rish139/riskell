#!/usr/bin/env bash
# The machine-readable output of the CLI, checked against schemas/*.schema.json: what a script or an agent may rely on.
# Builds nothing: it reads .build/release, so build first. Tests/cli/README.md says what is contracted and what is not.
#   Tests/cli/contract.sh
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
X=.build/release/riskell-ext
S=.build/release/riskell-setup

for binary in "$X" "$S"; do
  [ -x "$binary" ] || {
    echo "contract: $binary is not built, and this test builds nothing: swift build -c release" >&2
    exit 2
  }
done

# The checks below choose their own HOME and cache folder; one from the caller would change what is being tested.
unset RISKELL_CACHE_DIR RISKELL_EVENT_SOCKET RISKELL_CONFIG RISKELL_LAYOUT

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
checks=0
fails=0
pass() { checks=$((checks + 1)); printf 'PASS  %-14s %s\n' "$1" "$2"; }
fail() { checks=$((checks + 1)); fails=$((fails + 1)); printf 'FAIL  %-14s %s\n' "$1" "$2"; }
skip() { printf 'SKIP  %-14s %s\n' "$1" "$2"; }

# One JSON command: its stdout must validate against the schema file named for it, and it must exit with one of the codes it
# documents (a report that found a fault exits 1 and is still a report). The findings are printed under a FAIL, so the failure
# says which key, without opening the output by hand.
check_json() {   # check_json <schema> <exit codes> <what> <command...>
  local schema=$1 codes=$2 what=$3
  shift 3
  local out="$T/$schema.json" err="$T/$schema.err" rc=0 findings=""
  set +e
  "$@" > "$out" 2> "$err"
  rc=$?
  set -e
  case " $codes " in
    *" $rc "*) ;;
    *) fail "$schema" "$what: exit $rc, and this check knows $codes: $(head -n 2 "$err" | tr '\n' ' ')"
       return ;;
  esac
  if findings=$(python3 -I Tests/cli/jsonschema.py "schemas/$schema.schema.json" "$out"); then
    pass "$schema" "$what"
  else
    fail "$schema" "$what: the output does not match schemas/$schema.schema.json"
    printf '%s\n' "$findings" | sed 's/^/      /'
  fi
}

# The words the running bar answers. Reading the list writes nothing on the socket and needs nothing running.
check_json riskell-ctl 0 'riskell-ext ctl --list --json' "$X" ctl --list --json

# The log, read from a scratch cache folder: the same three lines whether this Mac has a log of its own or not.
mkdir -p "$T/log/cache" "$T/nolog/cache"
printf 'riskell starting\nwarming up\nready\n' > "$T/log/cache/riskell.log"
check_json riskell-log 0 'riskell-ext log 2 --json (a scratch log)' \
  env RISKELL_CACHE_DIR="$T/log/cache" "$X" log 2 --json
# and a machine where riskell has not run yet: an empty list under the same schema, and exit 1
check_json riskell-log 1 'riskell-ext log 5 --json (no log yet)' \
  env RISKELL_CACHE_DIR="$T/nolog/cache" "$X" log 5 --json

# The picture set. Exit 1 means this table and scripts/make-screenshots have drifted apart; the shape is the contract either way.
check_json riskell-snap "0 1" 'riskell-ext snap --list --json' "$X" snap --list --json

# The health report, against a home with nothing installed in it: no autostart, no config, no socket. Exit 1 is a report with a
# failed check in it, which is what a machine with nothing installed should say.
mkdir -p "$T/home"
check_json riskell-doctor "0 1" 'riskell-setup --doctor --json (a scratch home)' \
  env HOME="$T/home" "$S" --doctor --json

# The same report against this Mac, which is the only way the running bars' own answer is part of the check. It is a read: the
# `doctor` word only answers. With no socket there is nothing to ask, and the rest of the report was checked above.
socket="$HOME/.cache/riskell/ev.sock"
if [ -S "$socket" ]; then
  check_json riskell-doctor "0 1" 'riskell-setup --doctor --json (this Mac)' "$S" --doctor --json
else
  skip riskell-doctor "riskell-setup --doctor --json against the running bar: no socket at $socket"
fi

# The checker itself, or a checker that stopped checking would quietly pass every line above: one row with a key taken out.
cp "$T/riskell-ctl.json" "$T/broken.json"
python3 -I - "$T/broken.json" <<'PY'
import json, sys
document = json.load(open(sys.argv[1]))
del document["verbs"][0]["destructive"]
json.dump(document, open(sys.argv[1], "w"))
PY
if python3 -I Tests/cli/jsonschema.py schemas/riskell-ctl.schema.json "$T/broken.json" > /dev/null; then
  fail "the check" 'a ctl row without "destructive" was accepted: the checker is not checking'
else
  pass "the check" 'a ctl row without "destructive" is refused'
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "contract: $checks checked, all of them as promised"
else
  echo "contract: $fails of $checks checks failed"
  exit 1
fi
