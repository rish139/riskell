# Security

riskell runs as your user and draws windows over your screen. There is no telemetry and no account. What it can touch, and what it sends, is
listed in the README's "Data access" table. Compiled extensions run inside it with your rights and there is no sandbox.

## What is built in to keep it safe
- **Nothing sensitive is read unless you turn it on.** By default riskell reads no credentials, keychain items or browser data, and makes no
  usage request. The AI usage atom reads only Claude Code's own local session logs (token counts) and makes no network request. Two opt-in
  sources read more, after you say yes: `usage.claudeLimits` reads the Claude Code login token from the login keychain and sends it to
  Anthropic's usage endpoint (unofficial: Anthropic's terms do not allow using that token in other tools, so the account could be
  restricted); `usage.opencode` reads the opencode.ai session cookie from a browser profile and sends it to opencode.ai. The installer asks
  before turning either on, and `--yes` never does.
- **Extensions are code you choose.** `risk ext add <name>` shows you who wrote it, the license and the exact commit, says that it will run with
  your rights, and asks before anything is built (`--yes` answers for scripts). A pill's shell commands are shown first. The registry pins every
  listing to one commit, so what you read is what you get, and `risk ext update` shows the change and applies nothing without `--yes`.
- **The client does not trust a listing.** Only https repositories are cloned (git's `ext::` transport, which runs commands, is off, as are prompts
  and hooks); the commit, id, version and path are checked; a pill or theme file must be a plain small regular file inside the repository; the
  registry index is fetched over https only.
- **The project itself:** GitHub Actions are pinned to commits and run with a read-only token, Dependabot watches the actions and the Swift
  dependency, secret scanning and push protection are on, and `scripts/scrub-check.sh` keeps personal data out of the tree.

## Report a vulnerability
Privately: on GitHub, open this repository's *Security* tab and choose *Report a vulnerability*. Please do not open a public issue for one. You
will get an answer within a few days; this is a one-person project, so please be patient. A fix is released as a new patch version and credited
in the changelog if you want.

## Supported
The latest release only (see the releases page).
