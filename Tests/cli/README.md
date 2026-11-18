# The CLI's output: what is a contract, and what is only a screen

The CLI has one interface for a person and one for a script. The second is the JSON, and a script that reads it should not have to read
the source to know what it may count on. `Tests/cli/contract.sh` holds that line: it runs each command that prints JSON, validates the
output against a schema in `schemas/`, and prints one line per command.

```
swift build -c release          # the test builds nothing: it reads .build/release and says so when that is absent
Tests/cli/contract.sh           # add --update to re-record the screens (below)
```

## What is contracted

| command | schema | what a consumer may rely on |
|---|---|---|
| `riskell-ext ctl --list --json` | `schemas/riskell-ctl.schema.json` | every word, and whether it is `destructive` |
| `riskell-ext log N --json` | `schemas/riskell-log.schema.json` | the lines in order, each with its number in the file, and `truncated` |
| `riskell-ext snap --list --json` | `schemas/riskell-snap.schema.json` | each maker's id, who draws it, the files it writes, and the `feeds`/`from` link between the two sides |
| `riskell-setup --doctor --json` | `schemas/riskell-doctor.schema.json` | the sections, each check's `id` and `severity` and `source`, the counts, `firstFailure`, and `app.reachable` |

Three rules keep the schemas useful rather than brittle:

- **A required key is a promise.** Every key in a schema's `required` list is printed by every run, including the runs that found
  something wrong: a report with a failed check still exits 1 with the whole object on stdout.
- **A key that is only sometimes there is not required.** `fix` is there for a failed check and often not otherwise; `files.config.valid`
  and `files.config.keys` wait for a config to exist; `files.log.bytes` waits for a log. A consumer must test for them.
- **A new key is not a break.** No schema here forbids one: `additionalProperties: false` would turn a field nobody promised into a
  contract failure, and a contract test that fails when a command prints more is a test someone deletes. A schema is a floor, not a
  ceiling.

What is deliberately **not** contracted, having looked at it once:

- **Prose.** `label`, `summary`, `detail`, `fix`, a finding: sentences for a person, rewritten whenever they can be clearer. A check's
  `id` (`build.binary`) is the stable name, not its `detail`, which carries this machine's absolute paths.
- **Display groupings.** `ctl`'s `group` is how a screen sorts the table, not something a consumer should switch on.
- **Anything the app answers, beyond `reachable`.** The doctor prints the running bars' payload as they sent it, under their own
  `AppStatus.schema`. Only `reachable` is this report's to promise; when it is true the fields the bars always send (`schema`, `pid`,
  `version`, `atoms`, `bars`) are required too, and the rest is the app's business.
- **Incident values.** `generatedAt`, `running.pid`, `running.version`, `files.log.modifiedAt`, `log`'s `path`: true of one run on one
  Mac. They may be printed, not parsed.

## What is only a screen

`Tests/cli/golden/` holds three screens as plain text, and the same script compares each with what the command prints now:

```
COLUMNS=80 riskell-ext help           → Tests/cli/golden/help.txt
COLUMNS=80 riskell-ext help status    → Tests/cli/golden/help-status.txt
COLUMNS=80 riskell-ext snap --list    → Tests/cli/golden/snap-list.txt
```

`COLUMNS` is fixed so the wrapping is the recording's and not this terminal's, and the home is a scratch one so the line about the agent
says the same thing on a Mac that runs riskell and on a runner that does not. A difference is a decision, not a bug report: read the
diff, and if the new text is the right text, record it.

```
Tests/cli/contract.sh --update
git diff Tests/cli/golden        # read this before committing: it is the screen you are agreeing to
```

Nothing rewrites a recording on its own, and a fixture that is missing is a failure with the `--update` to run, not a silent pass.

## When a command gains a schema

1. Write `schemas/riskell-<thing>.schema.json` beside the others, in the shape they use: `$schema`, `$id`, `title`, a `description` that
   says what is promised, then `type`, `required` and `properties`. Describe the keys a consumer may rely on and leave the prose alone.
2. **The `$id` is the string the command prints in `schema`, and the same string is the file's name for it.** `riskell.ctl/1` is the
   `$id` of `riskell-ctl.schema.json`; `riskell-setup --doctor` prints its schema as the number `1`, so that file's `$id` is `"1"`.
   `Tests/cli/jsonschema.py` compares the two on every run, and a mismatch is a failure that says both values.
3. Add one `check_json` line to `Tests/cli/contract.sh`: the schema, the exit codes the command documents (a run that found something is
   still a good run), a one-line name, and the command. If it needs a running bar, a real home or a log, give it a scratch one and say so
   on the line; if it cannot be run without riskell running, gate it on the socket and let it print `SKIP` with the reason.
4. Bump the string in the command (`riskell.ctl/2`) when a key moves or changes meaning, and add the file for the new number rather than
   changing the old one in place: that is what lets an older script notice.

The validator is `Tests/cli/jsonschema.py`: a JSON Schema 2020-12 subset in plain `python3`, with no package to install. Its keyword list
is closed, so a schema that uses a keyword it cannot check fails instead of passing quietly, and the script checks the checker itself on
every run by feeding it a document with a required key taken out.

The one check that needs a running bar is the doctor against this Mac. A runner has no event socket, so it is skipped there, with the
path it looked in, and the summary counts it: a skipped check is never a pass.
