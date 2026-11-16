#!/bin/sh
# Fails (exit 1) if any git-tracked file holds personal data.
#   Generic patterns (below): workspace ids, home-folder paths, e-mail addresses (GitHub noreply addresses are allowed).
#   Deny-list (optional): one fixed string per line in $RISKELL_SCRUB_LIST, default ~/.config/riskell/scrub-denylist.txt.
#     That file lives outside the repo and is never committed.
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

  if [ -f "$deny" ]; then
    while IFS= read -r pat || [ -n "$pat" ]; do
      [ -n "$pat" ] || continue
      grep -n -F -- "$pat" "$f" | cut -d: -f1 | report "$f" "deny-list hit" >> "$hits"
    done < "$deny"
  fi
done < "$tmp"

if [ -s "$hits" ]; then
  cat "$hits"
  echo "scrub-check: $(wc -l < "$hits" | tr -d ' ') hit(s) in $(cut -d: -f1 "$hits" | sort -u | wc -l | tr -d ' ') file(s)"
  exit 1
fi
[ -f "$deny" ] || echo "scrub-check: no deny-list file (generic patterns only)"
echo "scrub-check: clean"
exit 0
