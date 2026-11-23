#!/bin/sh
# Fails (exit 1) if any git-tracked file holds personal data.
#   Generic patterns (below): workspace ids, home-folder paths, e-mail addresses (GitHub noreply addresses are allowed).
#   Deny-list (optional): one fixed string per line in $RISKELL_SCRUB_LIST, default ~/.config/riskell/scrub-denylist.txt.
#     That file lives outside the repo and is never committed.
#   Process wording: nothing in the repository says who or what wrote it or how the work was organised: no task labels, no talk of a
#     spec or a brief, no tool or model names, no attribution lines, and no file named after a task.
# Prints file:line and the kind of hit only. Matched text is never printed, deny-list strings included.
# Skipped: binary files, .git/, .build/.
set -u

root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "scrub-check: not inside a git checkout"; exit 2; }
cd "$root" || exit 2

deny=${RISKELL_SCRUB_LIST:-$HOME/.config/riskell/scrub-denylist.txt}
tmp=$(mktemp) || exit 2
hits=$(mktemp) || exit 2
trap 'rm -f "$tmp" "$hits"' EXIT INT TERM

git ls-files > "$tmp"

# Reads line numbers on stdin and prints "file:line: kind" for each. Only line numbers leave this function.
report() {
  while read -r n; do printf '%s:%s: %s\n' "$1" "$n" "$2"; done
}

while IFS= read -r f; do
  case $f in .git/*|.build/*) continue ;; esac
  [ -f "$f" ] || continue
  grep -Iq . "$f" 2>/dev/null || continue      # binary (or empty): nothing to scan

  grep -n -E 'wrk_[A-Za-z0-9]{10,}' "$f" | grep -v 'XAMPLE' | cut -d: -f1 | report "$f" "workspace id" >> "$hits"
  grep -n -E '/Users/[A-Za-z]' "$f" | grep -v '/Users/example' | cut -d: -f1 | report "$f" "home path" >> "$hits"
  grep -n -o -E '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$f" \
    | grep -v '@users\.noreply\.github\.com$' | cut -d: -f1 | report "$f" "e-mail address" >> "$hits"

  case $f in scripts/scrub-check.sh|AGENTS.md) ;; *)
    grep -n -i -E 'sub-?agent|deepseek|herdr|pi-subagents|mockups?\.sh|co-authored-by|generated with|model credit|assisted by (an? )?(ai|llm|model)' "$f" \
      | cut -d: -f1 | report "$f" "process or AI wording" >> "$hits"
    grep -n -E "([Tt]he|[Tt]his|[Ss]etup|[Rr]eaders) task('s| addition)|task [A-Z][0-9]?([^A-Za-z]|$)|([Tt]he|[Aa]) (spec|brief) (says|names|asks|fixed)|per the (spec|brief)" "$f" \
      | cut -d: -f1 | report "$f" "task wording" >> "$hits" ;;
  esac
  if [ -f "$deny" ]; then
    while IFS= read -r pat || [ -n "$pat" ]; do
      [ -n "$pat" ] || continue
      grep -n -F -- "$pat" "$f" | cut -d: -f1 | report "$f" "deny-list hit" >> "$hits"
    done < "$deny"
  fi
done < "$tmp"

git ls-files | grep -iE '(^|/)[^/]*(task|sub-?agent|deepseek|-d2\.|-u\.swift)[^/]*$' | sed 's/$/:1: file named after a task/' >> "$hits"
if [ -s "$hits" ]; then
  cat "$hits"
  echo "scrub-check: $(wc -l < "$hits" | tr -d ' ') hit(s) in $(cut -d: -f1 "$hits" | sort -u | wc -l | tr -d ' ') file(s)"
  exit 1
fi
[ -f "$deny" ] || echo "scrub-check: no deny-list file (generic patterns only)"
echo "scrub-check: clean"
exit 0
