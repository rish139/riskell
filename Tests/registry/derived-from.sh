#!/bin/zsh
# The provenance rule on its own: a manifest that says it was ported from somewhere must say which project, which commit, under what license
# and by whom, and `risk ext validate` refuses each way of leaving that claim incomplete (rule manifest.derived-from). The fixtures under
# Tests/registry/derived-from/ are one folder per case; the working example at Examples/load-ext must still validate with no derivedFrom.
#   Tests/registry/derived-from.sh            needs a release build of riskell-ext
root=${0:A:h:h:h}
X=$root/.build/release/riskell-ext
[[ -x $X ]] || { echo "build first: swift build -c release --product riskell-ext"; exit 2 }
D=$root/Tests/registry/derived-from
fails=0
rule=manifest.derived-from
ok() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fails=$((fails+1)); fi }
accepts() { ok "$1 is valid" "$X validate $D/$1 >/dev/null"; }
refuses() { ok "$1 is refused by $rule" "! $X validate $D/$1 >/dev/null 2>&1 && $X validate $D/$1 2>&1 | grep -q 'rule $rule:'"; }
accepts valid
ok "Examples/load-ext is valid with no derivedFrom" "$X validate $root/Examples/load-ext >/dev/null"
for c in not-an-object no-repo no-rev no-license no-authors short-rev unknown-license no-own-license; do refuses $c; done
echo; [[ $fails == 0 ]] && echo "all checks passed" || { echo "$fails check(s) failed"; exit 1; }
