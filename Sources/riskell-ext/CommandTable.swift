// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Rishabh Tiwari

import Foundation

// The one command table: every command a user may type, what it is for, and which spellings it takes over. `risk help` (the front door
// and per-command help), `risk completions` and `docs/CLI.md` are rendered from it, so the three cannot disagree. Internal `riskell --`
// debug flags are not commands: they stay out of the table.

/// Whether a name is part of the user CLI. A `stable` command is removed only with a note in CHANGELOG; a `dev` one is for CI and
/// developers: it still runs, but it is not listed in the front door, the completions or docs/CLI.md.
enum Tier: String, CaseIterable {
    case stable, dev
}

/// One subcommand of a pass-through (`ext`); a group (`wm`, `gestures`, `config`, `theme`) takes its own from the rows below.
struct Child {
    let name: String
    let summary: String

    init(_ name: String, _ summary: String) {
        self.name = name
        self.summary = summary
    }
}

/// One row: everything the generated screens say about a command.
struct Command {
    let usage: String          // the synopsis after `risk `, flags included: "status [--json] [--check]"
    let summary: String        // one line, imperative, lowercase, at most 60 characters
    let example: String        // one whole invocation, `risk ` included
    let tier: Tier
    let aliases: [String]      // other names for the same command, kept working
    let replaces: [String]     // the flags, scripts and older spellings this command takes over
    let children: [Child]      // a pass-through's own subcommands, e.g. ext's
    let group: String?         // the front door's group: "RUN", "LOOK", "CHANGE" or "EXTEND"
    let front: String?         // the one line the front door shows for it; nil for a row the front door does not list

    init(_ usage: String, _ summary: String, example: String, tier: Tier = .stable,
         aliases: [String] = [], replaces: [String] = [], children: [Child] = [],
         group: String? = nil, front: String? = nil) {
        self.usage = usage
        self.summary = summary
        self.example = example
        self.tier = tier
        self.aliases = aliases
        self.replaces = replaces
        self.children = children
        self.group = group
        self.front = front
    }

    /// The first word of the synopsis: the name a user types.
    var name: String { String(usage.split(separator: " ").first ?? "") }

    /// What the front door and the completions call it: the subcommand too, without the flags (`config show`).
    var display: String { subcommand.map { "\(name) \($0)" } ?? name }

    /// The second word when it is a plain subcommand (`config show`), nil otherwise (`log [N]`, `ext <subcommand>`).
    var subcommand: String? {
        guard let word = usage.split(separator: " ").dropFirst().first, let first = word.first, first.isLetter else { return nil }
        return String(word)
    }

    /// The command this row is a subcommand of: "config" for `config show`, nil for a command without a subcommand.
    var parent: String? { subcommand == nil ? nil : name }

    /// The `replaces` entries worth printing: everything except a spelling of this command itself (`risk status` under `risk status`,
    /// `risk restart` under `risk dev`, `risk log [N]` under `risk log [N] [--follow] [--json]`), which would only repeat the heading.
    var otherReplaces: [String] { replaces.filter { !namesSelf($0) } }

    /// Whether an entry is only this command again: `risk` followed by the command's name or an alias, and nothing that is not already
    /// in its own synopsis. A genuinely different spelling (`riskell-setup --check`, `risk ext (exit 10)`) answers false.
    private func namesSelf(_ source: String) -> Bool {
        var words = source.split(separator: " ").map(String.init)
        guard words.first == "risk" else { return false }
        words.removeFirst()
        let usage = usage.split(separator: " ").map(String.init)
        return ([name] + aliases).contains { spelling in
            let own = spelling.split(separator: " ").map(String.init)
            return words.starts(with: own) && words.dropFirst(own.count).allSatisfy(usage.contains)
        }
    }
}

// The user CLI first, in the order a user meets it: the front door's four groups, then the two commands that are not on it. Developer
// commands come after them. Nothing renders the second group but the command table itself: they keep working for CI and developers
// without being part of the user CLI.
let commandTable: [Command] = [
    Command("install [--no-build] [--dry-run]", "build, then start riskell now and at login",
            example: "risk install", replaces: ["scripts/risk install"],
            group: "RUN", front: "build, then start riskell now and at login"),
    Command("dev [--no-launch] [--dry-run]", "rebuild and restart the running agent",
            example: "risk dev", aliases: ["restart", "rebuild"],
            replaces: ["risk dev", "risk restart", "risk ext (exit 10)"],
            group: "RUN", front: "rebuild and restart the running agent"),
    Command("setup [--yes] [--dry-run]", "run the guided installer; flags answer its questions",
            example: "risk setup --dry-run", replaces: ["riskell-setup", "riskell-install"],
            group: "RUN", front: "the guided installer"),
    Command("uninstall [--dry-run] [--yes]", "stop riskell and remove its login agent",
            example: "risk uninstall --dry-run", replaces: ["riskell-setup --uninstall", "riskell-setup --remove-config"],
            group: "RUN", front: "stop riskell and remove its login agent"),
    Command("status [--json] [--check] [--all]", "check health and name the first failing check",
            example: "risk status --json", aliases: ["doctor"],
            replaces: ["risk status", "riskell-setup --check", "riskell --dump"],
            group: "LOOK", front: "health, with the first thing to fix named"),
    Command("log [N] [--follow] [--json]", "print the last few log lines, or follow them",
            example: "risk log 50 --json", replaces: ["risk log [N]", "tail ~/.cache/riskell/riskell.log"],
            group: "LOOK", front: "the last lines of the log, or follow it"),
    Command("config <subcommand>", "read and change riskell's settings without editing JSON",
            example: "risk config get theme", replaces: ["riskell --dump", "the paths scattered through README and docs/INSTALL.md"], children: [
                Child("path", "print the config, layout, cache, log and socket paths"),
                Child("show", "print the file as written, with secrets hidden"),
                Child("get", "print one setting by its dotted key"),
                Child("set", "change one setting and leave the rest as it was"),
                Child("edit", "open the file in $EDITOR and check what was saved"),
            ], group: "CHANGE", front: "read and change settings without editing JSON"),
    Command("ctl <word|--list> [--json] [--dry-run] [--yes]", "send one word to the running bar, or list them",
            example: "risk ctl overview --dry-run", replaces: ["printf overview | nc -U ~/.cache/riskell/ev.sock"],
            group: "CHANGE", front: "send one word to the running bar"),
    Command("gestures fix [--restart-dock] [--dry-run] [--yes]", "save the originals, then turn the conflicting keys off",
            example: "risk gestures fix --yes", replaces: ["riskell --gestures-fix --yes", "riskell-setup --gestures riskell"],
            group: "CHANGE", front: "turn off the trackpad keys that fight riskell"),
    Command("gestures restore [--dry-run] [--yes]", "put the saved key values back",
            example: "risk gestures restore", replaces: ["riskell --gestures-restore", "riskell-setup --restore-gestures"],
            group: "CHANGE"),
    Command("ext <subcommand>", "add, update, remove, validate and publish extensions",
            example: "risk ext add load", replaces: ["riskell-ext"], children: [
                Child("search", "search what the registry lists"),
                Child("info", "show one listing by name"),
                Child("add", "install one by name, folder or git url"),
                Child("update", "install what the registry pins now"),
                Child("publish", "check it is ready to be listed"),
                Child("remove", "take it out again"),
                Child("list", "list what is installed"),
                Child("validate", "check a folder against the rules"),
                Child("new", "scaffold a reading, atom, pill or theme"),
                Child("sync", "regenerate the lock's Swift files"),
            ], group: "EXTEND", front: "add, update, remove, validate and publish extensions"),
    Command("completions <zsh|fish|bash>", "print the shell completions for this table",
            example: "risk completions zsh"),
    Command("help [command]", "print this table, or one command in detail",
            example: "risk help gestures", replaces: ["the header of scripts/risk"]),

    // Developer commands: they still run for CI and developers, but they are not part of the user CLI.
    Command("theme list [--json]", "list every scheme with its resolved tokens",
            example: "risk theme list --json", tier: .dev, replaces: ["riskell --list-themes"]),
    Command("theme check [--scheme ID] [--json]", "check each scheme's contrast against its floors",
            example: "risk theme check --scheme nord", tier: .dev, replaces: ["riskell --check-themes"]),
    Command("theme import <file> [--id ID] [--force] [--dry-run] [--json]", "bring a Base16 scheme in from another shell",
            example: "risk theme import base16-nord.yaml --id nord", tier: .dev,
            replaces: ["cp <scheme>.yaml ~/.config/riskell/themes/"]),
    Command("gestures status [--json]", "show which trackpad and dock keys fight riskell",
            example: "risk gestures status", tier: .dev, replaces: ["riskell --gestures-fix (dry run)"]),
    Command("wm status [--json]", "show which window manager is driving the rail",
            example: "risk wm status --json", tier: .dev, replaces: ["risk wm"]),
    Command("wm export [--json]", "save each window's workspace number",
            example: "risk wm export", tier: .dev, replaces: ["risk wm export"]),
    Command("wm import [--dry-run]", "put each saved window back on its number",
            example: "risk wm import --dry-run", tier: .dev, replaces: ["risk wm import"]),
    Command("wm start", "start omniwm and put each window on its number",
            example: "risk wm start", tier: .dev, replaces: ["risk wm omniwm"]),
    Command("version [--json]", "print riskell, kit and lockfile versions",
            example: "risk version --json", tier: .dev, replaces: ["riskell --version", "riskell-setup --version"]),
    Command("fit [--scale N] [--panels] [--json]", "run pass/fail checks on each fake display",
            example: "risk fit --panels", tier: .dev, replaces: ["riskell --check-fit", "riskell --check-panel"]),
    Command("snap <maker>…|all|--list [--out DIR] [--theme ID|all] [--scale N] [--display WxH] [--card ATOM] [--json] [--dry-run]",
            "render the picture set from scratch instances",
            example: "risk snap card clock --out /tmp/p", tier: .dev,
            replaces: ["riskell --snap", "riskell --pop", "riskell --settings --snap", "scripts/overview-check"]),
    Command("bench [idle|card <atom>|all] [--runs N] [--list] [--json]", "re-measure the efficiency table on this machine",
            example: "risk bench idle --runs 3", tier: .dev, replaces: ["scripts/idle-cpu", "scripts/resource-check"],
            children: [Child("emit-doc [--json]", "write the table as data: docs/efficiency.json")]),
    Command("gallery [--ascii] [--plain] [--width N]", "draw every screen from fixed data",
            example: "risk gallery --plain", tier: .dev),
    Command("self-test [name] [--json]", "run the ci checks: installer, extensions, weather, usage",
            example: "risk self-test installer", tier: .dev,
            replaces: ["riskell-setup --self-test", "riskell --ext-selftest", "riskell --weather-selftest",
                       "riskell --usage-selftest", "riskell --key-test", "riskell --lock-test"]),
]

/// The row for a name or one of its aliases. A group (`config`, `wm`) has no row of its own: it is asked for its subcommands instead.
func command(named name: String) -> Command? {
    commandTable.first { $0.display == name || $0.aliases.contains(name) }
}

/// The subcommands a command or a group offers: declared for a pass-through (`ext`), derived from the table for a group (`wm`, `gestures`,
/// `config`, `theme`).
func subcommands(of name: String) -> [Child] {
    if let row = command(named: name), !row.children.isEmpty { return row.children }
    return commandTable.compactMap { row in row.parent == name ? row.subcommand.map { Child($0, row.summary) } : nil }
}
