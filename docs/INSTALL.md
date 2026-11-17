# Installing riskell

`./install.sh` runs the guided installer, `riskell-setup`: a short terminal flow that checks this Mac, asks the questions that matter,
writes the settings, starts riskell and checks that it is running. Nothing is written until the last screen's Install.

```sh
./install.sh              # the guided flow
./install.sh --yes        # no questions: detected defaults
./install.sh --dry-run    # show the plan and the JSON that would be written; write nothing
```

The installer is part of the same Swift package as riskell (`Sources/riskell-setup`, Foundation only). Build it on its own with
`swift build -c release --product riskell-setup`; it compiles in a few seconds and does not depend on the riskell target.

## What the flow asks

| Step | Question | Writes |
|---|---|---|
| Welcome | macOS 14 or newer, Swift (Command Line Tools), an existing config, the launch agent, window managers found | nothing |
| 1 Window manager | Auto, OmniWM, yabai, AeroSpace, custom commands, none | `wm` |
| 2 Bars | Minimal, Classic (recommended), Full; cards Flush or Chat; bars Floating, Hug or as the preset | `layout.json` (see below) |
| 3 Theme | one of the 11 schemes, with a live preview | `theme` |
| 4 Weather | a city (one lookup to open-meteo.com, after you stop typing), coordinates by hand, or Skip | `location` |
| 5 Usage | Three sources, all off at first: Claude Code usage from its local logs (no credentials, no network); Claude plan limits (reads the keychain, unofficial, asks first, needs the first); OpenCode Go usage (reads a browser cookie, asks first, with its workspace id and profiles folder) | `usage.claude`, `usage.claudeLimits`, `usage.opencode` |
| 6 Gestures | macOS (default) or riskell's own 3-finger swipe; read-only conflict check; optionally turn the conflicting macOS gestures off | `gestures`, and with the option on, the trackpad and Dock settings (originals saved) |
| 7 Scale | Auto (recommended) or a number from 0.5 to 2.0 | `scale` only when custom |
| 8 Review | the summary, the files that will change, then Install, Show what would change, or Back | nothing |

The only network request is step 4, made with `/usr/bin/curl` to `geocoding-api.open-meteo.com`. It sends the city name you typed.

The two opt-in usage sources ask first. Turning one on opens a panel that says what is read and sent; only `y` turns it on, and any
other key leaves it off. The review screen then lists what is on, with "reads the keychain" or "reads a browser cookie" beside it.
`--yes` never turns either on: they are on only when a flag below, or the panel, says so.

## What it writes

Paths are derived from `$HOME`.

- **`~/.config/riskell/config.json`**: the installer owns the keys `wm`, `theme`, `location`, `usage`, `gestures` and `scale`. It sets
  or removes those and keeps every other key (`pills`, `spacing`, ...) as it was. Inside `usage` it owns only `claude`, `claudeLimits` and
  `opencode`; the token limits and any other key there are kept. When the file existed, a copy is kept as
  `config.json.bak-YYYYMMDD-HHMMSS` first. The file is written through a temporary file and a rename.
- **`~/.config/riskell/layout.json`**: written only when there is no layout yet, or when you choose "Replace my layout" on the review
  screen. Otherwise your layout is left alone. A replaced file is backed up the same way.
  Classic is riskell's built-in default (`Sources/riskell/Layout.swift`); Minimal keeps only the top bar; Full adds the right bar.
- **`~/.config/riskell/gesture-backup.json`**: only when the gesture option is on (written by `riskell --gestures-fix`).
- **A `risk` link** in the first of `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin` that is on `PATH` and writable, pointing at
  `scripts/risk`. When none of them is on `PATH`, the installer adds `~/.local/bin` to `PATH` for you: a block between `# >>> riskell >>>`
  and `# <<< riskell <<<` is appended to `~/.zshrc` (created when missing) and to `~/.bash_profile`, `~/.bashrc` and
  `~/.config/fish/config.fish` when they exist. A file that existed is copied to `<name>.bak-riskell-<time>` first, and a file that
  already has the block is left alone. The review screen lists it, `--no-path` skips it, and `--uninstall` removes the block. A new
  terminal is needed before `risk` is found.
- **The launch agent** `~/Library/LaunchAgents/com.rish.riskell.plist`, written and started by `scripts/risk install`.

## The steps of an install

1. Build riskell (`swift build -c release --product riskell`), started in the background as soon as you leave the welcome screen,
   skipped when `.build/release/riskell` is newer than every source file.
2. Write `config.json` (merge and backup).
3. Write `layout.json` (or keep it).
4. Trackpad gestures, only when you asked: `riskell --gestures-fix --yes`.
5. Link `risk`.
6. Start the agent: `scripts/risk install`.
7. Health check: the agent is loaded, the socket `~/.cache/riskell/ev.sock` appears, and the log has no `fatal` or `error` line.

A failed step stops the install and shows the step, the last lines of its output and what to do. Running `riskell-setup` again is
safe: every step is idempotent (the config is merged, a link is replaced, the agent is restarted), so nothing is applied twice.

## Flags

| Flag | Meaning |
|---|---|
| `--yes`, `-y` | No questions. Detected defaults, plus the answer flags below. |
| `--dry-run` | Print the plan and the exact JSON that would be written. Writes nothing. With the TUI, the Install action shows the same plan. |
| `--check` | Doctor: the welcome checklist, then the socket and the log. Exits 1 when something is wrong. |
| `--uninstall` | Stops riskell, removes its launch agent and the `risk` link. Asks first; `--yes` skips the question. Keeps `~/.config/riskell` unless `--remove-config`. `--restore-gestures` also restores the trackpad. |
| `--version`, `--help` | |
| `--wm auto\|omniwm\|yabai\|aerospace\|command\|none` | Window manager (with `--yes`). |
| `--theme ID` | A scheme id from `installer/themes.json`, for example `nord`. |
| `--bars minimal\|classic\|full` | Preset. |
| `--cards flush\|chat` | Card style. |
| `--city "Name"` | Looked up once; the first match is used. Needs the network. |
| `--gestures riskell\|system` | Gestures. |
| `--claude` | Claude Code usage on, from its local logs (no credentials, no network). |
| `--claude-limits` | The real Claude plan limits too. Reads the keychain login token and asks Anthropic; unofficial, may breach its terms. Implies `--claude`. The flag is the consent. |
| `--opencode-workspace wrk_...` | OpenCode Go usage: reads an opencode.ai browser cookie. The id is checked (`wrk_` then 6 to 64 letters or digits). The flag is the consent. |
| `--opencode-profiles DIR` | The browser profiles folder for OpenCode (default: Zen's). Needs `--opencode-workspace`. |
| `--scale N\|auto` | Scale, from 0.5 to 2.0. |
| `--replace-layout` | Replace an existing `layout.json`. |
| `--repo PATH` | The checkout (found from the working directory when omitted). |
| `--no-build` | Do not build. |
| `--no-launch` | Do not start the agent and do not link `risk`. |

Without a terminal (stdout is not a TTY) the guided flow does not start: the installer prints the plan and asks for `--yes`.

## Undo

- `risk uninstall` stops riskell and removes the launch agent. `riskell-setup --uninstall` also removes the `risk` link.
- Settings: restore a `config.json.bak-…` or `layout.json.bak-…` copy next to the file, or remove the keys you do not want.
- Trackpad gestures changed by the installer: `riskell --gestures-restore --yes`.
- To remove everything: `riskell-setup --uninstall --yes --remove-config`.

## Installing by hand

1. `swift build -c release`
2. Copy `scripts/risk` somewhere on your `PATH` (or link it), then `risk install`.
3. To choose settings, edit `~/.config/riskell/config.json` (keys in `docs/CONFIG.md`) and `layout.json` (`docs/BARS.md`), or use the
   riskell preferences with ctrl-alt-,.

## Privacy

Nothing leaves the Mac except the weather lookup (the city name you typed) and the weather requests riskell makes for the weather card
you turned on. The usage card reads Claude Code's local logs and makes no request and reads no credentials. Two opt-in sources read more,
only after you say yes: the Claude plan limits read the Claude Code login token from the keychain and send it to Anthropic; OpenCode Go
usage reads the opencode.ai session cookie from a browser profile and sends it to opencode.ai.

## Development notes

- Snapshots of every screen at 100x32, 80x24 and 60x20 live in `docs/installer-snapshots/` (`*.txt` plain, `*.ansi` with colour).
  Regenerate with `riskell-setup --snapshot-dir docs/installer-snapshots`.
- `riskell-setup --self-test` runs the unit-style checks (config merge, presets against `riskell --dump`, geocoding, detection parsing,
  arguments). `python3 -I Tests/installer/pty_flow.py` drives the whole flow in a pseudo-terminal with a scratch HOME.
- Themes: edit `installer/themes.json`, then `python3 -I scripts/gen-installer-themes` (writes `Sources/riskell-setup/ThemeData.swift`).
