#!/bin/sh
# riskell: one command to install.
#   ./install.sh            the guided installer (a short, clean terminal flow)
#   ./install.sh --yes      no questions: detected defaults
#   ./install.sh --dry-run  show what would change, write nothing
# Everything after the script name is passed on to the installer (see docs/INSTALL.md).
set -eu
# The checkout this script lives in, even when it is run through a symlink (Homebrew links it into bin as `riskell-install`).
self=$0
while [ -L "$self" ]; do
  link=$(readlink "$self")
  case $link in /*) self=$link ;; *) self="$(dirname "$self")/$link" ;; esac
done
root=$(cd "$(dirname "$self")" && pwd)
dim(){ printf '\033[2m%s\033[0m\n' "$*"; }
say() { printf '%s\n' "$*"; }
die() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || die "riskell is for macOS."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 14 ] || die "riskell needs macOS 14 or newer (this is $(sw_vers -productVersion))."

# The one real requirement: Apple's Swift toolchain (the Command Line Tools are enough; Xcode is not needed).
if ! xcode-select -p >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1; then
  die "Apple's Command Line Tools are needed to build riskell. Run:  xcode-select --install   then run ./install.sh again."
fi

# The guided installer is a small Swift program in this package (Sources/riskell-setup). It builds in seconds with the same Command Line Tools
# riskell itself needs, then starts at once while the full app builds in the background. Nothing else is required, nothing is downloaded.
bin="$root/.build/release/riskell-setup"
if [ ! -x "$bin" ] || [ -n "$(find "$root/Sources/riskell-setup" "$root/Package.swift" -newer "$bin" -print -quit 2>/dev/null)" ]; then
  if [ -d "$root/Sources/riskell-setup" ]; then
    dim "Preparing the installer..."
    (cd "$root" && swift build -c release --product riskell-setup >/dev/null 2>&1) || true
  fi
fi

if [ -x "$bin" ]; then
  "$bin" --repo "$root" "$@"; exit $?
fi

# Fallback, so installing never depends on anything extra: no questions, detected defaults, the same result as `--yes`.
say "riskell"
dim "The guided installer is not available here, so this is the quick install (no questions). Defaults are chosen for your Mac;"
dim "change anything later in the layout editor (ctrl-alt-,) or in ~/.config/riskell/config.json."
for a in "$@"; do [ "$a" = --dry-run ] && dry=1; done
if [ "${dry:-0}" = 1 ]; then
  say "would run: $root/scripts/risk install   (builds riskell, starts it now and at login)"
  say "would link: scripts/risk -> ~/.local/bin/risk"
  exit 0
fi
"$root/scripts/risk" install
mkdir -p "$HOME/.local/bin" && ln -sf "$root/scripts/risk" "$HOME/.local/bin/risk"
say ""
say "riskell is running."
dim "ctrl-alt-,   open the layout editor     risk status   check it     risk log 30   recent log"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) dim "Add ~/.local/bin to your PATH to use the \`risk\` command everywhere." ;; esac
