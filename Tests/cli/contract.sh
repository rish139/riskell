#!/usr/bin/env bash
# The machine-readable output of the CLI, checked against schemas/*.schema.json, and six screens checked against
# Tests/cli/golden/: the first three are a contract, and a recording is rewritten on purpose.
# Builds nothing: it reads .build/release, so build first. Tests/cli/README.md says what is contracted and what is not.
#   Tests/cli/contract.sh [--update]
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
X=.build/release/riskell-ext
S=.build/release/riskell-setup

update=0
for arg in "$@"; do
  case $arg in
    --update) update=1 ;;
    *) echo "contract: unknown argument \"$arg\"; the only one is --update" >&2; exit 2 ;;
  esac
done

for binary in "$X" "$S"; do
  [ -x "$binary" ] || {
    echo "contract: $binary is not built, and this test builds nothing: swift build -c release" >&2
    exit 2
  }
done

# The checks below choose their own HOME and cache folder; one from the caller would change what is being tested.
unset RISKELL_CACHE_DIR RISKELL_EVENT_SOCKET RISKELL_CONFIG RISKELL_LAYOUT RISKELL_LOG_FILE

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
checks=0
fails=0
skipped=0
pass() { checks=$((checks + 1)); printf 'PASS  %-14s %s\n' "$1" "$2"; }
fail() { checks=$((checks + 1)); fails=$((fails + 1)); printf 'FAIL  %-14s %s\n' "$1" "$2"; }
skip() { skipped=$((skipped + 1)); printf 'SKIP  %-14s %s\n' "$1" "$2"; }

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

# One screen: the plain text the command prints, compared with the file that records it. A screen is not a contract, so a
# difference here is a decision: look at the diff, and rewrite the recording with --update when the new text is the right text.
# COLUMNS is fixed so the wrapping is the recording's, not this terminal's; a scratch home makes the line about the agent the
# same one on a Mac that runs riskell and on a runner that does not.
golden() {   # golden <name> <what> <command...>
  local name=$1 what=$2
  shift 2
  local got="$T/golden-$name.txt" want="$root/Tests/cli/golden/$name.txt" rc=0
  set +e
  COLUMNS=80 HOME="$T/golden-home" RISKELL_CACHE_DIR="$T/golden-home/.cache/riskell" \
    "$@" > "$got" 2> "$T/golden-$name.err"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    fail "golden $name" "$what: exit $rc: $(head -n 2 "$T/golden-$name.err" | tr '\n' ' ')"
    return
  fi
  if [ "$update" -eq 1 ]; then
    mkdir -p "$(dirname "$want")"
    cp "$got" "$want"
    pass "golden $name" "$what (recorded)"
    return
  fi
  if [ ! -f "$want" ]; then
    fail "golden $name" "$what: no Tests/cli/golden/$name.txt: record it with --update"
    return
  fi
  if diff -u -L "recorded: Tests/cli/golden/$name.txt" -L now "$want" "$got" > "$T/golden-$name.diff"; then
    pass "golden $name" "$what"
  else
    fail "golden $name" "$what: the screen changed, and - is the recording, + is now"
    sed 's/^/      /' "$T/golden-$name.diff"
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

# Three screens: the front door, one command's page, and the picture set. Nothing here is a promise about the text, only a
# record of it, so a change shows up as a diff and is either fixed or recorded.
golden help 'riskell-ext help' "$X" help
golden help-status 'riskell-ext help status' "$X" help status
golden snap-list 'riskell-ext snap --list' "$X" snap --list
# The kit's screens, recorded from fixed data: the palette and the clock are the gallery's own, so only a change to the kit moves them.
# A UTF-8 locale is named for the two coloured ones because the glyph set is the plain one when the locale does not say UTF-8.
golden gallery-plain 'riskell-ext gallery --plain' env LC_ALL=en_US.UTF-8 "$X" gallery --plain
golden gallery-ascii 'riskell-ext gallery --ascii --plain' "$X" gallery --ascii --plain
golden gallery-color 'riskell-ext gallery --color' env LC_ALL=en_US.UTF-8 "$X" gallery --color

# The front door reaches every command: each read-only form must print its own output and exit 0, never the wrapper's header. The
# scratch home keeps the wrapper's own mkdir and the commands' path lookups away from this Mac. A dry run is a read: it writes nothing.
front_home="$T/front-home"
mkdir -p "$front_home"
front() {   # front <what> <command...>
  local what=$1 out=$T/front.out err=$T/front.err rc=0
  shift
  set +e
  env HOME="$front_home" RISKELL_CONFIG="$front_home/.config/riskell/config.json" \
    RISKELL_LAYOUT="$front_home/.config/riskell/layout.json" \
    RISKELL_CACHE_DIR="$front_home/.cache/riskell" \
    RISKELL_EVENT_SOCKET="$front_home/.cache/riskell/ev.sock" \
    RISKELL_GESTURE_BACKUP="$front_home/gesture-backup.json" \
    RISKELL_PREFS_SUFFIX=-riskell-contract \
    "$root/scripts/risk" "$@" > "$out" 2> "$err"
  rc=$?
  set -e
  if grep -q '^# riskell control' "$out"; then
    fail front-door "$what: printed the wrapper's header instead of running"
  elif [ "$rc" -ne 0 ]; then
    fail front-door "$what: exit $rc: $(head -n 2 "$err" | tr '\n' ' ')"
  else
    pass front-door "$what"
  fi
}
front 'config path' config path
front 'version' version
front 'theme list --json' theme list --json
# `gestures status --json` is advertised but prints the dry run's text, so the read-only form checked is the dry run itself.
if [ -x .build/release/riskell ]; then
  front 'gestures fix --dry-run' gestures fix --dry-run
else
  skip front-door 'gestures fix --dry-run: .build/release/riskell is not built'
fi
front 'setup --dry-run' setup --dry-run
skip front-door 'self-test --list: there is no self-test listing, and running one is not read-only'
front 'bench --list' bench --list
front 'snap --list' snap --list
front 'gallery --plain' gallery --plain

# An unknown command is bad usage, not the header text and a success: the kit's error shape on stderr, and exit 2.
set +e
env HOME="$front_home" "$root/scripts/risk" nonsense > "$T/front-unknown.out" 2> "$T/front-unknown.err"
rc=$?
set -e
if [ "$rc" -eq 2 ] && grep -q "unknown command 'nonsense'" "$T/front-unknown.err"; then
  pass front-door 'an unknown command exits 2'
else
  fail front-door "an unknown command: exit $rc: $(head -n 2 "$T/front-unknown.err" | tr '\n' ' ')"
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


# The readers' screens: the log, the socket words and the config file. Every line comes from a scratch home and a scratch file, so
# the path in a header is the same on this Mac and on a runner, and only a change to the screen moves a recording.
mkdir -p "$T/golden-home/.config/riskell" "$T/golden-home/.cache/riskell"
readers_cfg="$T/golden-home/.config/riskell/config.json"
cat > "$readers_cfg" <<'JSON'
{
  "theme": "gruvbox",
  "scale": 1.25,
  "tray": true,
  "pills": ["clock", "battery"],
  "apiKey": "hidden"
}
JSON
cat > "$T/golden-home/.cache/riskell/riskell.log" <<'LOG'
12:04:11 info overview opened on workspace 3
12:04:12 info touch frames arriving, 3 fingers down
12:04:19 warn touch no frame for 2 s, reattaching
12:04:30 error weather fetch failed (offline); retry in 600 s
12:04:31 info weather serving the cached forecast
LOG

golden readers-log 'riskell-ext log 5 (a scratch log)' "$X" log 5
golden readers-log-ascii 'riskell-ext log 5, plain glyphs' env RISKELL_ASCII=1 "$X" log 5
golden readers-ctl-list 'riskell-ext ctl --list' "$X" ctl --list
golden readers-config-path 'riskell-ext config path' env RISKELL_CONFIG="$readers_cfg" "$X" config path
golden readers-config-show 'riskell-ext config show' env RISKELL_CONFIG="$readers_cfg" "$X" config show
cat > "$T/golden-home/.config/riskell/set.json" <<'JSON'
{
  "theme": "gruvbox"
}
JSON
golden readers-config-set 'riskell-ext config set theme nord' \
  env RISKELL_CONFIG="$T/golden-home/.config/riskell/set.json" "$X" config set theme nord

# One more golden for the one screen that writes to stderr: it has to keep its exit code, and stdout has to stay empty.
golden_err() {   # golden_err <name> <exit> <what> <command...>
  local name=$1 wanted=$2 what=$3
  shift 3
  local got="$T/golden-$name.txt" want="$root/Tests/cli/golden/$name.txt" rc=0
  set +e
  COLUMNS=80 HOME="$T/golden-home" RISKELL_CACHE_DIR="$T/golden-home/.cache/riskell" \
    "$@" > "$T/golden-$name.out" 2> "$got"
  rc=$?
  set -e
  if [ "$rc" -ne "$wanted" ]; then
    fail "golden $name" "$what: exit $rc, and this check knows $wanted: $(head -n 2 "$got" | tr '\n' ' ')"
    return
  fi
  if [ -s "$T/golden-$name.out" ]; then
    fail "golden $name" "$what: a failed command wrote to stdout"
    return
  fi
  if [ "$update" -eq 1 ]; then
    mkdir -p "$(dirname "$want")"
    cp "$got" "$want"
    pass "golden $name" "$what (recorded)"
    return
  fi
  if [ ! -f "$want" ]; then
    fail "golden $name" "$what: no Tests/cli/golden/$name.txt: record it with --update"
    return
  fi
  if diff -u -L "recorded: Tests/cli/golden/$name.txt" -L now "$want" "$got" > "$T/golden-$name.diff"; then
    pass "golden $name" "$what"
  else
    fail "golden $name" "$what: the screen changed, and - is the recording, + is now"
    sed 's/^/      /' "$T/golden-$name.diff"
  fi
}
golden_err readers-ctl-notrunning 1 'riskell-ext ctl overview, with no socket' \
  env RISKELL_EVENT_SOCKET="$T/golden-home/.cache/riskell/no-sock" "$X" ctl overview
# The status screen is drawn from a fixed Report in the installer's self-test and compared there with
# Tests/cli/golden/status-screen.txt and status-screen-ascii.txt. The self-test runs here with a scratch home, and the two PASS lines
# say those recordings still match; another failure is the self-test's own, reported the same way.
self_home="$T/self-home"
mkdir -p "$self_home"
set +e
env HOME="$self_home" "$S" --self-test > "$T/self-test.out" 2> "$T/self-test.err"
self_rc=$?
set -e
if [ "$self_rc" -eq 0 ] && grep -qx 'PASS the status screen is as recorded' "$T/self-test.out" \
   && grep -qx 'PASS the status screen in plain ASCII is as recorded' "$T/self-test.out"; then
  pass status-screen 'the status screen is as recorded, in Unicode and plain ASCII'
else
  fail status-screen "the self-test exited $self_rc: $(grep -E '^FAIL' "$T/self-test.out" | head -n 3 | tr '\n' ' ')"
fi

# --- lifecycle: risk install, dev and uninstall's screens (Lifecycle.swift) -------------------------------------------------
# The steps are stubbed: this file never runs a real install, restart or uninstall. The stub logs the step it was asked for and
# answers the three read-only probes; RISKELL_STEPS_FAIL makes one step fail, so the error shape is checked without a real one.
life_home="$T/life-home"
steps="$T/life-steps.sh"
steps_log="$T/life-steps.log"
mkdir -p "$life_home"
cat > "$steps" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$RISKELL_STEPS_LOG"
name=${1:-}
case $name in
  pid) echo "${RISKELL_STEPS_PID:-4242}"; exit 0 ;;
  loaded|bundled) exit "${RISKELL_STEPS_PROBE:-1}" ;;
esac
[ "$name" = "${RISKELL_STEPS_FAIL:-}" ] && { echo "the build failed for the test: a line"; echo "a second line"; exit 1; }
exit 0
STUB
chmod +x "$steps"
: > "$steps_log"
life() {   # life <what> <command...>: the stub and a scratch home, nothing real
  local what=$1
  shift
  env HOME="$life_home" RISKELL_STEPS="$steps" RISKELL_STEPS_LOG="$steps_log" "$@"
}

# A dry run prints the plan and touches nothing: the three recordings are the byte-stable screens.
golden lifecycle-dev-dry-run 'riskell-ext lifecycle dev --dry-run' \
  life dev "$X" lifecycle dev --dry-run
golden lifecycle-install-dry-run 'riskell-ext lifecycle install --dry-run' \
  life install "$X" lifecycle install --dry-run
golden lifecycle-uninstall-dry-run 'riskell-ext lifecycle uninstall --dry-run' \
  life uninstall "$X" lifecycle uninstall --dry-run

# No mutating step was called: the probes (loaded, bundled, pid) are the only steps a dry run may make.
if grep -Eq '^(build|plist|reload|kickstart|stop|unplist)$' "$steps_log"; then
  fail lifecycle 'a dry run called a mutating step: '"$(sort -u "$steps_log" | tr '\n' ' ')"
else
  pass lifecycle 'the three dry runs called no mutating step'
fi

# A probe that says the agent is loaded marks its row as already satisfied, with the kit's `has`.
set +e
env HOME="$life_home" RISKELL_STEPS="$steps" RISKELL_STEPS_LOG="$steps_log" RISKELL_STEPS_PROBE=0 \
  "$X" lifecycle install --dry-run > "$T/life-satisfied.out" 2> "$T/life-satisfied.err"
rc=$?
set -e
if [ "$rc" -eq 0 ] && grep -q 'has   load' "$T/life-satisfied.out"; then
  pass lifecycle 'a satisfied step says has instead of would'
else
  fail lifecycle "a satisfied step: exit $rc: $(head -n 2 "$T/life-satisfied.out" | tr '\n' ' ')"
fi

# Off a terminal, uninstall must refuse without --yes: the error shape on stderr, exit 2, nothing stopped.
set +e
life uninstall "$X" lifecycle uninstall > "$T/life-uninstall.out" 2> "$T/life-uninstall.err" < /dev/null
rc=$?
set -e
if [ "$rc" -eq 2 ] && grep -q 'risk uninstall --yes' "$T/life-uninstall.err" \
  && ! grep -Eq '^(stop|unplist)$' "$steps_log"; then
  pass lifecycle 'uninstall without --yes exits 2 and stops nothing'
else
  fail lifecycle "uninstall without --yes: exit $rc: $(head -n 2 "$T/life-uninstall.err" | tr '\n' ' ')"
fi

# A stubbed dev run is the non-interactive screen: one line per finished step, then the summary with the pid.
set +e
life dev "$X" lifecycle dev > "$T/life-dev.out" 2> "$T/life-dev.err" < /dev/null
rc=$?
set -e
if [ "$rc" -eq 0 ] && grep -q '  build ' "$T/life-dev.out" && grep -q '  write ' "$T/life-dev.out" \
  && grep -q '  load ' "$T/life-dev.out" && grep -q 'restarted · pid 4242' "$T/life-dev.out"; then
  pass lifecycle 'a stubbed dev run prints its steps and the pid'
else
  fail lifecycle "a stubbed dev run: exit $rc: $(head -n 4 "$T/life-dev.out" | tr '\n' ' ')"
fi

# A failing step stops the run: its own line, then the error block on stderr, exit 1.
set +e
env RISKELL_STEPS="$steps" RISKELL_STEPS_LOG="$steps_log" RISKELL_STEPS_FAIL=build \
  "$X" lifecycle dev > "$T/life-build.out" 2> "$T/life-build.err" < /dev/null
rc=$?
set -e
if [ "$rc" -eq 1 ] && grep -q 'build failed' "$T/life-build.err" && grep -q 'risk status' "$T/life-build.err" \
  && grep -q 'the build failed for the test' "$T/life-build.err"; then
  pass lifecycle 'a failed step prints the error block and exits 1'
else
  fail lifecycle "a failed step: exit $rc: $(head -n 3 "$T/life-build.err" | tr '\n' ' ')"
fi

# --- theme: the tokens of the scheme in force, and the two forms of `risk version` (Tty.themed, scripts/risk) ------------------
# The versions need nothing built: VERSION, the kit's pin in Package.resolved and the entries in extensions.lock.json. Both forms are
# read here from those same three files (beside the wrapper's own parsing, which uses jq when it is installed), so a release bump moves
# the command and this check together.
theme_home="$T/theme-home"
mkdir -p "$theme_home"
# A hint is what a person types, so no fix in the report names a path into the build or at the wrapper script: `risk dev`, `risk install`,
# `risk gestures fix --yes`, as docs/CLI.md spells them. The doctor is run against a scratch home, which is the run whose fixes exist.
set +e
env HOME="$theme_home" RISKELL_CACHE_DIR="$theme_home/.cache/riskell" \
  "$root/.build/release/riskell-setup" --doctor --json > "$T/theme-doctor.json" 2> "$T/theme-doctor.err"
rc=$?
set -e
if [ -s "$T/theme-doctor.json" ] && ! grep -qE '"fix": ".*(\.build/|scripts/risk)' "$T/theme-doctor.json"; then
  pass theme-fixes 'every fix in the report is a command a person types, not a path into the build'
else
  fail theme-fixes "a fix in the report names a build path, or the doctor printed nothing (exit $rc)"
fi
want_version=$(cat VERSION)
want_kit=$(awk '/"riskell-kit"/ { pin = 1 } pin && /"version"/ { print; exit }' Package.resolved \
             | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
lock_entries() {   # the compiled extensions one record holds: what ships, and what this checkout installed for itself
  local n=0
  [ -f "$1" ] && n=$(grep -c '"entry"[[:space:]]*:' "$1" || true)
  echo "${n:-0}"
}
want_lock=$(( $(lock_entries extensions.lock.json) + $(lock_entries extensions.local.json) ))
want_json=$(printf '{"riskell":"%s","kit":"%s","lock":%s}' "$want_version" "$want_kit" "${want_lock:-0}")

set +e
env HOME="$theme_home" "$root/scripts/risk" version --json > "$T/theme-version.json" 2> "$T/theme-version.err"
rc=$?
set -e
if [ "$rc" -eq 0 ] && [ "$(cat "$T/theme-version.json")" = "$want_json" ]; then
  pass theme-version 'risk version --json is one object: riskell, kit and lock'
else
  fail theme-version "risk version --json: exit $rc, printed $(head -n 2 "$T/theme-version.json" | tr '\n' ' '), wanted $want_json"
fi

set +e
env HOME="$theme_home" "$root/scripts/risk" version > "$T/theme-version.txt" 2> "$T/theme-version-plain.err"
rc=$?
set -e
if [ "$rc" -eq 0 ] && [ "$(cat "$T/theme-version.txt")" = "riskell $want_version" ]; then
  pass theme-version 'risk version is the one line it was: riskell and the number'
else
  fail theme-version "risk version: exit $rc, printed $(head -n 2 "$T/theme-version.txt" | tr '\n' ' ')"
fi

# The theme itself is the built `riskell`'s answer (`Tty.themed`), so a scratch checkout with a stub in its place shows both directions
# through a terminal a person uses: the stub's tokens reach the screen, and with no stub at all the screen is plain text rather than a
# guessed palette. A pipe is plain either way, which is why the two runs go through Tests/cli/pty-run.py; there is no other way to give a shell
# command a tty, and no override for the built binary's path: RISKELL_ROOT picks the checkout it is looked for in.
theme_root="$T/theme-root"
bare_root="$T/bare-root"
mkdir -p "$theme_root/.build/release" "$bare_root"
cp VERSION extensions.lock.json "$theme_root/"
cp VERSION extensions.lock.json "$bare_root/"
cat > "$theme_root/.build/release/riskell" <<'STUB'
#!/usr/bin/env bash
# the palette Tty.themed() asks for: the accent is a red nothing else on the front door would print
printf '%s\n' '{"tokens":{"bg":"#000000","tile":"#111111","canvas":"#000000","text1":"#ffffff","text2":"#eeeeee","text3":"#dddddd","text4":"#cccccc","accent":"#ff0000","ok":"#00ff00","warn":"#ffff00","crit":"#ff00ff","info":"#00ffff","critInk":"#ff00ff","prov":"#dddddd","amberDim":"#cccccc"}}'
STUB
chmod +x "$theme_root/.build/release/riskell"

themed() {   # themed <checkout>: the front door through a terminal, in whatever palette Tty.themed() found
  env -u NO_COLOR HOME="$theme_home" RISKELL_CACHE_DIR="$theme_home/.cache/riskell" COLUMNS=80 \
    TERM=xterm-256color COLORTERM=truecolor RISKELL_ROOT="$1" \
    python3 -I "$root/Tests/cli/pty-run.py" "$root/.build/release/riskell-ext" help
}
if ! command -v python3 > /dev/null 2>&1; then
  skip theme 'the palette the built riskell answers: no python3 to give the command a tty'
  skip theme 'no built riskell leaves the screen plain: no python3 to give the command a tty'
else
  themed "$theme_root" > "$T/theme-stub.txt" 2> /dev/null || true
  if grep -qF $'\033[0;38;2;255;0;0m' "$T/theme-stub.txt"; then
    pass theme 'the built riskell is asked, and its tokens are what the screen is drawn in'
  else
    fail theme 'the built riskell is asked for the palette: no escape in its accent colour reached the screen'
  fi
  themed "$bare_root" > "$T/theme-bare.txt" 2> /dev/null || true
  if [ -s "$T/theme-bare.txt" ] && ! grep -q $'\033' "$T/theme-bare.txt"; then
    pass theme 'with no built riskell the screen is plain, not a guessed palette'
  else
    fail theme 'a tty with no built riskell should be plain, and an escape sequence reached it'
  fi
fi
# --- the guided installer's screens: fixed data, a fixed width, so the recording is the kit's text and nothing else --------------
golden u-setup-welcome 'riskell-setup --snapshot welcome (80x24)' \
  env LC_ALL=en_US.UTF-8 "$S" --snapshot welcome --size 80x24
golden u-setup-review 'riskell-setup --snapshot review (60x20)' \
  env LC_ALL=en_US.UTF-8 "$S" --snapshot review --size 60x20
golden u-setup-progress 'riskell-setup --snapshot install-mid (80x24)' \
  env LC_ALL=en_US.UTF-8 "$S" --snapshot install-mid --size 80x24

# --- the ext and gestures screens -------------------------------------------------------------------------------------------
# Everything below runs on scratch copies: a small checkout whose lock has two compiled extensions (one with its folder on disk,
# one installed from a URL), a config folder with two file extensions, and a registry index in a file. Nothing fetches, clones or writes a preference, and no screen here reads the
# real machine (`--gestures-test` draws from fixed data and RISKELL_PREFS_SUFFIX keeps the status reads in throwaway domains).
ext_golden() {   # ext_golden <name> <exit> <what> <command...>: the screen, and the exit code the command already had
  local name=$1 wanted=$2 what=$3
  shift 3
  local got="$T/golden-$name.txt" want="$root/Tests/cli/golden/$name.txt" rc=0
  set +e
  COLUMNS=80 HOME="$T/golden-home" RISKELL_CACHE_DIR="$T/golden-home/.cache/riskell" "$@" > "$got" 2> "$T/golden-$name.err"
  rc=$?
  set -e
  if [ "$rc" -ne "$wanted" ]; then
    fail "golden $name" "$what: exit $rc, and this check knows $wanted: $(head -n 2 "$T/golden-$name.err" | tr '\n' ' ')"
    return
  fi
  if [ "$update" -eq 1 ]; then
    mkdir -p "$(dirname "$want")"
    cp "$got" "$want"
    pass "golden $name" "$what (recorded)"
    return
  fi
  if [ ! -f "$want" ]; then
    fail "golden $name" "$what: no Tests/cli/golden/$name.txt: record it with --update"
    return
  fi
  if diff -u -L "recorded: Tests/cli/golden/$name.txt" -L now "$want" "$got" > "$T/golden-$name.diff"; then
    pass "golden $name" "$what"
  else
    fail "golden $name" "$what: the screen changed, and - is the recording, + is now"
    sed 's/^/      /' "$T/golden-$name.diff"
  fi
}

ext_root="$T/ext-root"
ext_cfg="$T/ext-home/.config/riskell"
mkdir -p "$ext_root/Packages/alpha" "$ext_cfg/pills" "$ext_cfg/themes"
cat > "$ext_root/extensions.lock.json" <<'JSON'
[
  {
    "entry": "AlphaPackage",
    "id": "alpha",
    "module": "AlphaExt",
    "package": "alpha",
    "path": "Packages/alpha",
    "product": "AlphaExt",
    "version": "1.2.0"
  },
  {
    "entry": "BetaPackage",
    "id": "beta",
    "kind": "reading",
    "module": "BetaExt",
    "package": "beta",
    "product": "BetaExt",
    "revision": "0123456789abcdef0123456789abcdef01234567",
    "summary": "a figure from a command, with a hover card",
    "url": "https://example.invalid/beta",
    "version": "0.4.0"
  }
]
JSON
cat > "$ext_root/Packages/alpha/riskell.json" <<'JSON'
{
  "id": "alpha",
  "kind": "atom",
  "name": "Alpha",
  "version": "1.2.0",
  "license": "MIT",
  "summary": "the first extension: a gauge and a hover card",
  "module": "AlphaExt",
  "entry": "AlphaPackage",
  "atoms": ["alpha"]
}
JSON
cat > "$ext_cfg/config.json" <<'JSON'
{
  "theme": "nord"
}
JSON
cat > "$ext_cfg/extensions.json" <<'JSON'
[
  {
    "files": ["pills/gauges.json"],
    "id": "gauges",
    "kind": "pill",
    "name": "Gauges",
    "repo": "https://example.invalid/gauges",
    "rev": "1111111111111111111111111111111111111111",
    "summary": "two numbers from a command",
    "version": "2.0.0"
  },
  {
    "files": ["themes/nord.yaml"],
    "id": "nord",
    "kind": "theme",
    "name": "Nord",
    "repo": "https://example.invalid/nord",
    "rev": "2222222222222222222222222222222222222222",
    "summary": "a quiet blue-grey scheme, in use",
    "version": "0.3.0"
  }
]
JSON
touch "$ext_cfg/pills/gauges.json" "$ext_cfg/themes/nord.yaml"
mkdir -p "$T/ext-registry"
cat > "$T/ext-registry/index.json" <<'JSON'
{"listings": [
  {"id": "alpha", "kind": "atom", "name": "Alpha", "version": "1.2.0", "summary": "the first extension: a gauge and a hover card",
   "repo": "https://example.invalid/alpha", "rev": "0123456789abcdef0123456789abcdef01234567", "license": "MIT"},
  {"id": "gamma", "kind": "reading", "name": "Gamma", "version": "0.1.0", "summary": "a load figure and a card, ported from another project",
   "repo": "https://example.invalid/gamma", "rev": "3333333333333333333333333333333333333333", "license": "Apache-2.0",
   "kit": "^0.6", "atoms": ["gamma", "pulse"], "authors": ["A Person"],
   "derivedFrom": {"repo": "https://github.com/example/load", "rev": "4444444444444444444444444444444444444444", "license": "MIT", "authors": ["Someone"]},
   "settings": [
     {"key": "hotAt", "label": "Gauge full at %", "type": "number", "min": 50, "max": 200, "step": 25, "default": 100},
     {"key": "icon", "label": "Show icon", "type": "bool", "default": true},
     {"key": "unit", "label": "Unit", "type": "choice", "options": ["load", "percent"], "default": "load"}
   ]}
]}
JSON
ext_env=(env "RISKELL_ROOT=$ext_root" "RISKELL_CONFIG=$ext_cfg/config.json" "RISKELL_REGISTRY=$T/ext-registry/index.json")

ext_golden ext-list 0 'riskell-ext list (a scratch checkout)' "${ext_env[@]}" "$X" list
ext_golden ext-search 0 'riskell-ext search card (one installed, one not)' "${ext_env[@]}" "$X" search card
ext_golden ext-info 0 'riskell-ext info gamma' "${ext_env[@]}" "$X" info gamma
ext_golden ext-none 0 'riskell-ext search nothinghere' "${ext_env[@]}" "$X" search nothinghere
mkdir -p "$T/ext-empty"
echo '[]' > "$T/ext-empty/extensions.lock.json"
ext_golden ext-empty 0 'riskell-ext list, nothing installed' env "RISKELL_ROOT=$T/ext-empty" "RISKELL_CONFIG=$T/ext-empty/config.json" "$X" list
# validate: the problem line is a contract, so the recording is of a fixture with one finding and of a valid extension
ext_golden ext-validate 1 'riskell-ext validate (one finding)' env "RISKELL_ROOT=$ext_root" "$X" validate Tests/registry/derived-from/no-repo
ext_golden ext-validate-valid 0 'riskell-ext validate Examples/load-ext' env "RISKELL_ROOT=$ext_root" "$X" validate Examples/load-ext
# new, add, remove and sync: one result line each, and the exit 10 that says the build changed
mkdir -p "$T/ext-new"
ext_golden ext-new 0 'riskell-ext new pill upinfo' env "RISKELL_ROOT=$ext_root" sh -c 'cd "$1" && exec "$2" new pill upinfo' sh "$T/ext-new" "$root/$X"
cp -R "$ext_root" "$T/ext-work"
cp -R Examples/load-ext "$T/ext-work/load-ext"
ext_work=(env "RISKELL_ROOT=$T/ext-work" "RISKELL_CONFIG=$ext_cfg/config.json" "RISKELL_REGISTRY=$T/ext-registry/index.json")
ext_golden ext-add 10 'riskell-ext add <dir> (exit 10 rebuilds)' "${ext_work[@]}" "$X" add "$T/ext-work/load-ext"
# An install is the checkout's own business: the local record and Local/ take it, and every file of the scratch checkout is as it was.
if diff -q "$ext_root/extensions.lock.json" "$T/ext-work/extensions.lock.json" > /dev/null \
   && grep -q '"id" : "load-ext"' "$T/ext-work/extensions.local.json" \
   && grep -q '("load-ext", LoadExt.LoadPackage.self)' "$T/ext-work/Local/Sources/RiskellLocal/LocalPackages.swift"; then
  pass ext-local 'an install writes extensions.local.json and Local/, and changes no tracked file'
else
  fail ext-local 'an install touched the scratch checkout: the lock, the local record or Local/ is not what it should be'
fi
ext_golden ext-remove 10 'riskell-ext remove (exit 10 rebuilds)' "${ext_work[@]}" "$X" remove load-ext
if [ ! -e "$T/ext-work/extensions.local.json" ] && [ ! -e "$T/ext-work/Local" ]; then
  pass ext-local 'the last remove takes the local record and Local/ with it'
else
  fail ext-local 'the last remove left extensions.local.json or Local/ behind'
fi
ext_golden ext-sync 0 'riskell-ext sync' "${ext_work[@]}" "$X" sync

# The gestures screens. `--gestures-test` draws from fixed data, and `--status --json` reads throwaway domains named by the suffix, so
# neither touches the real settings and neither writes: the backup path is a scratch file that must still not exist afterwards.
if [ -x .build/release/riskell ]; then
  ext_golden gestures-screens 0 'riskell --gestures-test' env LC_ALL=en_US.UTF-8 .build/release/riskell --gestures-test
  ext_golden gestures-status-json 0 'riskell --gestures-fix --status --json (throwaway domains)' \
    env RISKELL_PREFS_SUFFIX=-riskell-contract RISKELL_GESTURE_BACKUP="$T/golden-home/.config/riskell/gesture-backup.json" .build/release/riskell --gestures-fix --status --json
  ext_golden gestures-status 0 'riskell --gestures-fix --status (throwaway domains)' \
    env RISKELL_PREFS_SUFFIX=-riskell-contract RISKELL_GESTURE_BACKUP="$T/golden-home/.config/riskell/gesture-backup.json" .build/release/riskell --gestures-fix --status
  # The wrapper's status word is the read-only one: it passes --status, whatever else is on the line.
  set +e
  wrapper_json=$(env HOME="$front_home" RISKELL_PREFS_SUFFIX=-riskell-contract RISKELL_GESTURE_BACKUP="$T/gesture-backup.json" \
    "$root/scripts/risk" gestures status --json 2> "$T/gestures-wrapper.err")
  wrapper_rc=$?
  set -e
  if [ "$wrapper_rc" -eq 0 ] && [ "$wrapper_json" = '{"conflicts":[],"ok":true}' ]; then
    pass gestures 'risk gestures status --json is the read-only JSON'
  else
    fail gestures "risk gestures status --json: exit $wrapper_rc: $(head -n 2 "$T/gestures-wrapper.err" | tr '\n' ' ')"
  fi
  if [ -e "$T/golden-home/.config/riskell/gesture-backup.json" ]; then
    fail gestures 'a status or dry run wrote a backup'
  else
    pass gestures 'the status and dry-run forms wrote nothing'
  fi
  # A restore that has something to put back: the backup is one this test wrote, and the run is the dry one, so nothing is restored.
  # The domains carry the suffix a backup written under RISKELL_PREFS_SUFFIX would have, so the run reads throwaway domains only.
  backup="$T/golden-home/.config/riskell/gesture-backup.json"
  cat > "$backup" <<'JSON'
{"entries": [
  {"domain": "com.apple.AppleMultitouchTrackpad-riskell-contract", "key": "TrackpadThreeFingerHorizSwipeGesture", "original": 2},
  {"domain": "com.apple.dock-riskell-contract", "key": "showMissionControlGestureEnabled", "original": true}
]}
JSON
  cp "$backup" "$T/gesture-backup.before"
  ext_golden gestures-restore 0 'riskell --gestures-restore (dry run, throwaway domains)' \
    env RISKELL_PREFS_SUFFIX=-riskell-contract RISKELL_GESTURE_BACKUP="$backup" .build/release/riskell --gestures-restore
  if cmp -s "$backup" "$T/gesture-backup.before"; then
    pass gestures 'the restore dry run left the backup as it was'
  else
    fail gestures 'the restore dry run changed the backup'
  fi
else
  skip gestures 'the gestures screens: .build/release/riskell is not built'
fi

# --- status: the compact screen is the default, --all is the full list (DoctorScreen.swift, KeyLine.swift) -------------------
# The installer's self-test compares both screens with Tests/cli/golden (status-screen* and status-compact*); these checks are the flag's
# contract, read from the same scratch home twice: --all is only more text, --json is the same report either way, and the compact screen
# names --all so the long list can be found.
status_home="$T/status-home"
mkdir -p "$status_home"
status_report() {   # status_report <file> <flags...>
  local out=$1
  shift
  env HOME="$status_home" RISKELL_CACHE_DIR="$status_home/.cache/riskell" COLUMNS=72 "$S" --doctor "$@" > "$out" 2> /dev/null
}
set +e
status_report "$T/status-compact.out"
compact_rc=$?
status_report "$T/status-all.out" --all
all_rc=$?
status_report "$T/status-compact.json" --json
json_rc=$?
status_report "$T/status-all.json" --all --json
all_json_rc=$?
set -e
compact_lines=$(wc -l < "$T/status-compact.out" | tr -d ' ')
all_lines=$(wc -l < "$T/status-all.out" | tr -d ' ')
if [ "$compact_rc" -eq "$all_rc" ] && [ "$compact_lines" -lt "$all_lines" ]; then
  pass status "--doctor is the compact screen ($compact_lines lines) and --all the full list ($all_lines), same exit code"
else
  fail status "compact exit $compact_rc ($compact_lines lines), --all exit $all_rc ($all_lines lines)"
fi
# The report carries the time, the pid and the log's line count, so two runs are compared by their shape: the same schema, sections
# and check ids in the same order. --all draws text; it has nothing to say to the JSON.
if [ "$json_rc" -eq "$all_json_rc" ] && python3 -I - "$T/status-compact.json" "$T/status-all.json" <<'PY'
import json, sys
def shape(path):
    document = json.load(open(path))
    return (document["schema"], document["ok"], document["exit"],
            [[section["id"], [check["id"] for check in section["checks"]]] for section in document["sections"]])
sys.exit(0 if shape(sys.argv[1]) == shape(sys.argv[2]) else 1)
PY
then
  pass status '--all with --json is just --json'
else
  fail status '--all changed the JSON report'
fi
if grep -qx '  risk status --all every check, with its detail' "$T/status-compact.out" \
   && ! grep -q 'every check, with its detail' "$T/status-all.out"; then
  pass status 'the compact screen points at --all, and the full list does not'
else
  fail status 'the --all hint is missing from the compact screen, or the full list prints it'
fi

# --- the developer commands draw with the kit (Bench.swift, Snap.swift, ThemeCommand.swift) ------------------------------------
# Two lists that start nothing, two screens the built app answers, and one refusal each: a wrong flag is the kit's error block on
# stderr with exit 2, never a bare `usage:` line. theme needs .build/release/riskell, which answers --list-themes and --check-themes.
golden dev-bench-list 'riskell-ext bench --list' "$X" bench --list
golden dev-snap-list 'riskell-ext snap --list' "$X" snap --list
if [ -x .build/release/riskell ]; then
  golden dev-theme-list 'riskell-ext theme list' "$X" theme list
  golden dev-theme-check 'riskell-ext theme check' "$X" theme check
else
  skip dev-screens 'theme list and check: .build/release/riskell is not built'
fi
golden_err dev-bench-error 2 'riskell-ext bench --nope' "$X" bench --nope
golden_err dev-snap-error 2 'riskell-ext snap --nope' "$X" snap --nope
golden_err dev-theme-error 2 'riskell-ext theme list --nope' "$X" theme list --nope
golden_err dev-gallery-error 2 'riskell-ext gallery --nope' "$X" gallery --nope
# --- d2: the installer, the app's checks and the wrapper print the kit's screens --------------------------------------------
# A wrong flag is the kit's error block on stderr: the problem, the usage line, and the command that lists every option. Nothing is on
# stdout, and no line starts with the old `riskell-setup:` prefix.
set +e
env HOME="$T/golden-home" COLUMNS=80 "$S" --bogus > "$T/d2-setup-bogus.out" 2> "$T/d2-setup-bogus.err"
d2_rc=$?
set -e
if [ "$d2_rc" -eq 2 ] && [ ! -s "$T/d2-setup-bogus.out" ] && grep -q "unknown option --bogus" "$T/d2-setup-bogus.err" \
   && grep -q "risk help setup" "$T/d2-setup-bogus.err" && ! grep -q '^riskell-setup:' "$T/d2-setup-bogus.err"; then
  pass setup-error 'a wrong flag is the error block, with risk help setup, and exit 2'
else
  fail setup-error "a wrong flag: exit $d2_rc: $(head -n 3 "$T/d2-setup-bogus.err" | tr '\n' ' ')"
fi

# `riskell-ext error` is the one shape the wrapper's failures are drawn in: the block on stderr, nothing on stdout, exit 2.
set +e
env COLUMNS=80 "$X" error "a thing failed" --detail "what it was doing" --try "risk help|every command" > "$T/d2-error.out" 2> "$T/d2-error.err"
d2_rc=$?
set -e
if [ "$d2_rc" -eq 2 ] && [ ! -s "$T/d2-error.out" ] && grep -q "a thing failed" "$T/d2-error.err" \
   && grep -q "what it was doing" "$T/d2-error.err" && grep -q "risk help" "$T/d2-error.err"; then
  pass error-block 'riskell-ext error is the error block on stderr, and exits 2'
else
  fail error-block "riskell-ext error: exit $d2_rc: $(head -n 3 "$T/d2-error.err" | tr '\n' ' ')"
fi

# The wrapper hands its own failures to that command, so a checkout with the tool built prints the block and not a bare `risk:` line.
set +e
env HOME="$T/golden-home" COLUMNS=80 "$root/scripts/risk" nonsense > "$T/d2-wrapper.out" 2> "$T/d2-wrapper.err"
d2_rc=$?
set -e
if [ "$d2_rc" -eq 2 ] && grep -q "unknown command 'nonsense'" "$T/d2-wrapper.err" \
   && grep -q "try" "$T/d2-wrapper.err" && ! grep -q '^risk:' "$T/d2-wrapper.err"; then
  pass wrapper-error 'an unknown command is the error block: the title, then what to try'
else
  fail wrapper-error "an unknown command: exit $d2_rc: $(head -n 3 "$T/d2-wrapper.err" | tr '\n' ' ')"
fi

golden d2-setup-help 'riskell-setup --help' "$S" --help
golden_err d2-setup-error 2 'riskell-setup --bogus (a wrong flag)' "$S" --bogus
golden_err d2-error-block 2 'riskell-ext error (the wrapper failure shape)' \
  "$X" error "the build failed" --detail "swift build said no" --try "risk dev|try again" --try "risk log 30|what it said"
if [ -x .build/release/riskell ]; then
  golden d2-key-test 'riskell --key-test' .build/release/riskell --key-test
  golden d2-check-themes 'riskell --check-themes' .build/release/riskell --check-themes
  golden_err d2-fit-error 2 'riskell --check-fit with no layout' env -u RISKELL_LAYOUT .build/release/riskell --check-fit
else
  skip d2 'the app checks: .build/release/riskell is not built'
fi

echo
# --- HOME is the home: a scratch HOME must never reach the real ~/.config/riskell ------------------------------------------------
# `config set` writes, so it is the sharpest probe: it has to land in the folder HOME names and leave the real file alone.
home_probe="$T/home-probe"
mkdir -p "$home_probe/.config/riskell"
echo '{}' > "$home_probe/.config/riskell/config.json"
real_cfg="$HOME/.config/riskell/config.json"
real_before=$( [ -f "$real_cfg" ] && md5 -q "$real_cfg" || echo none )
env -u RISKELL_CONFIG HOME="$home_probe" "$X" config set probe.key 1 > /dev/null 2>&1 || true
real_after=$( [ -f "$real_cfg" ] && md5 -q "$real_cfg" || echo none )
if grep -q '"key"' "$home_probe/.config/riskell/config.json" && [ "$real_before" = "$real_after" ]; then
  pass home 'a scratch HOME is where config set writes, and the real config is untouched'
else
  fail home "config set under a scratch HOME wrote to the wrong place (scratch has the key: $(grep -c '"key"' "$home_probe/.config/riskell/config.json"); real file changed: $([ "$real_before" = "$real_after" ] && echo no || echo YES))"
fi

if [ "$fails" -eq 0 ]; then
  echo "contract: $checks checked, all of them as promised${skipped:+ ($skipped skipped)}"
else
  echo "contract: $fails of $checks checks failed${skipped:+ ($skipped skipped)}"
  exit 1
fi
