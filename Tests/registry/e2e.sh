#!/bin/zsh
# The storefront end to end, on scratch copies and local file:// repositories (never the real lock, config or network):
# a compiled atom, a pill and a theme are listed, checked, indexed, searched, installed by name, updated (dry, then --yes), refused when the listing and
# the manifest disagree, and removed. Needs a release build of riskell-ext and the riskell-registry checkout (REGISTRY_REPO, default ../riskell-registry).
#   Tests/registry/e2e.sh
root=${0:A:h:h:h}
reg=${REGISTRY_REPO:-$root/../riskell-registry}
X=$root/.build/release/riskell-ext
[[ -x $X ]] || { echo "build first: swift build -c release --product riskell-ext"; exit 2; }
[[ -f $reg/scripts/check-listing.py ]] || { echo "skipped: no riskell-registry checkout at $reg"; exit 0; }
T=$(mktemp -d); trap 'rm -rf $T' EXIT
fails=0
ok() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fails=$((fails+1)); fi }
mkdir -p $T/root $T/cfg $T/repos $T/reg/listings $T/cache
(cd $root && git archive HEAD | tar -x -C $T/root); cp -R $reg/scripts $reg/schema $T/reg/
export RISKELL_ROOT=$T/root RISKELL_CONFIG=$T/cfg/config.json RISKELL_CACHE_DIR=$T/cache RISKELL_REGISTRY=$T/reg REGISTRY_ALLOW_FILE=1 RISKELL_EXT=$X
echo '{}' > $T/cfg/config.json
mkrepo() { (cd $T/repos/$1 && git init -q -b main && git add -A && git -c user.email=t@t -c user.name=t commit -q -m init && git tag v$2); }
cp -R $root/Examples/load-ext $T/repos/load-ext; rm -rf $T/repos/load-ext/.build
(cd $T/repos && $X new pill upinfo >/dev/null && $X new theme mytheme >/dev/null)
mkrepo load-ext 1.0.0; mkrepo upinfo 0.1.0; mkrepo mytheme 0.1.0
list() {   # list <name> : write listings/<name>.json from the repository's manifest and HEAD
  python3 - $T $1 <<'PY'
import json,subprocess,sys
T,n=sys.argv[1:3]; m=json.load(open(f"{T}/repos/{n}/riskell.json"))
rev=subprocess.run(["git","-C",f"{T}/repos/{n}","rev-parse","HEAD"],capture_output=True,text=True).stdout.strip()
d={"id":m["id"],"kind":m["kind"],"name":m["name"],"summary":m["summary"],"repo":"file://"+f"{T}/repos/{n}","rev":rev,"version":m["version"],"license":m["license"],"keywords":[n]}
for k in ("kit","atoms"):
    if m.get(k): d[k]=m[k]
json.dump(d,open(f"{T}/reg/listings/{m['id']}.json","w"))
PY
}
index() { (cd $T/reg && python3 scripts/check-listing.py >/dev/null && python3 scripts/build-index.py >/dev/null); }
for n in load-ext upinfo mytheme; do list $n; done
ok "the listings pass the checks" "(cd $T/reg && python3 scripts/check-listing.py >/dev/null)"
ok "a wrong commit is refused" "! (cd $T/reg && python3 - <<'PY'
import json; d=json.load(open('listings/mytheme.json')); d['rev']='0'*40; json.dump(d,open('/tmp/bad-listing.json','w'))
PY
cp $T/reg/listings/mytheme.json $T/mytheme.bak; cp /tmp/bad-listing.json listings/mytheme.json; python3 scripts/check-listing.py mytheme >/dev/null 2>&1; r=\$?; cp $T/mytheme.bak listings/mytheme.json; exit \$r)"
index
ok "search finds by name" "[[ \$($X search load) == *load-ext* ]]"
ok "search finds by keyword" "[[ \$($X search mytheme) == *mytheme* ]]"
ok "info shows the pin" "[[ \$($X info load-ext) == *'pinned to'* ]]"
$X add load-ext >/dev/null 2>&1; rc=$?
ok "a compiled add asks for a rebuild (exit 10)" "[[ $rc == 10 ]]"
ok "the lock has it, with its version" "grep -q '\"version\" : \"1.0.0\"' $T/root/extensions.lock.json"
ok "a pill is installed as a file" "$X add upinfo >/dev/null 2>&1 && [[ -f $T/cfg/pills/upinfo.json ]]"
ok "a theme is installed as a file" "$X add mytheme >/dev/null 2>&1 && [[ -f $T/cfg/themes/mytheme.yaml ]]"
ok "list shows all three" "[[ \$($X list | grep -cE '^(load-ext|upinfo|mytheme) ') == 3 ]]"
# the pill's author ships 0.2.0
(cd $T/repos/upinfo && python3 - <<'PY'
import json; m=json.load(open("riskell.json")); m["version"]="0.2.0"; json.dump(m,open("riskell.json","w"))
p=json.load(open("pill.json")); p["run"]="echo 43"; json.dump(p,open("pill.json","w"))
PY
git -c user.email=t@t -c user.name=t commit -qam 0.2.0 && git tag v0.2.0)
list upinfo; index
ok "update shows the change and applies nothing" "[[ \$($X update) == *'nothing was changed'* ]] && grep -q 'echo 42' $T/cfg/pills/upinfo.json"
ok "update --yes applies it" "$X update --yes >/dev/null 2>&1 && grep -q 'echo 43' $T/cfg/pills/upinfo.json"
ok "then it is up to date" "[[ \$($X update) == *'up to date'* ]]"
python3 -c "import json;p='$T/reg/listings/load-ext.json';d=json.load(open(p));d['version']='9.9.9';json.dump(d,open(p,'w'))"; (cd $T/reg && python3 scripts/build-index.py >/dev/null)
ok "a listing that disagrees with the manifest is refused" "! $X add load-ext >/dev/null 2>&1"
ok "an unknown name is refused" "! $X add nothing-here >/dev/null 2>&1"
ok "remove takes a pill's files away" "$X remove upinfo >/dev/null 2>&1 && [[ ! -e $T/cfg/pills/upinfo.json ]]"
ok "remove takes a theme's files away" "$X remove mytheme >/dev/null 2>&1 && [[ ! -e $T/cfg/themes/mytheme.yaml ]]"
$X remove load-ext >/dev/null 2>&1; rc=$?
ok "remove of a compiled one asks for a rebuild" "[[ $rc == 10 ]]"
echo; [[ $fails == 0 ]] && echo "all checks passed" || { echo "$fails check(s) failed"; exit 1; }
