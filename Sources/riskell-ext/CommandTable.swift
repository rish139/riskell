// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Rishabh Tiwari

import Foundation

// The one command table: every command a user may type, what it is for, and which spellings it takes over. `risk help` (the front door
// and per-command help), `risk completions` and `docs/CLI.md` are rendered from it, so the three cannot disagree. Internal `riskell --`
// debug flags are not commands: they stay out of the table.

/// Whether a name and its flags are settled. An experimental command may change or go; a stable one is removed only with a note in CHANGELOG.
enum Tier: String, CaseIterable {
    case stable, experimental
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

    init(_ usage: String, _ summary: String, example: String, tier: Tier = .stable,
         aliases: [String] = [], replaces: [String] = [], children: [Child] = []) {
        self.usage = usage
        self.summary = summary
        self.example = example
        self.tier = tier
        self.aliases = aliases
        self.replaces = replaces
        self.children = children
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

    /// The group this row belongs to: "config" for `config show`, nil for a command without a subcommand.
    var group: String? { subcommand == nil ? nil : name }

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

// Stable commands first, in the order a user meets them; experimental ones after.
let commandTable: [Command] = [
    Command("install [--no-build] [--dry-run]", "build, then start riskell now and at login",
            example: "risk install", replaces: ["scripts/risk install"]),
    Command("uninstall [--all] [--keep-config] [--dry-run] [--yes]", "stop riskell and remove its login agent",
            example: "risk uninstall --dry-run", replaces: ["riskell-setup --uninstall", "riskell-setup --remove-config"]),
    Command("dev [--no-launch]", "rebuild and restart the running agent",
            example: "risk dev", aliases: ["restart", "rebuild"],
            replaces: ["risk dev", "risk restart", "risk ext (exit 10)"]),
    Command("status [--json] [--check]", "check health and name the first failing check",
            example: "risk status --json", aliases: ["doctor"],
            replaces: ["risk status", "riskell-setup --check", "riskell --dump"]),
    Command("log [N] [--follow] [--json]", "print the last few log lines, or follow them",
            example: "risk log 50 --json", replaces: ["risk log [N]", "tail ~/.cache/riskell/riskell.log"]),
    Command("ctl <word|--list> [--json] [--dry-run] [--yes]", "send one word to the running bar, or list them",
            example: "risk ctl overview --dry-run", replaces: ["printf overview | nc -U ~/.cache/riskell/ev.sock"]),
    Command("setup [--yes] [--dry-run]", "run the guided installer; flags answer its questions",
            example: "risk setup --dry-run", replaces: ["riskell-setup", "riskell-install"]),
    Command("config show [--json]", "show the resolved config and where each key came from",
            example: "risk config show --json", replaces: ["riskell --dump"]),
    Command("config path [--json]", "print the config, layout, socket and log paths",
            example: "risk config path", replaces: ["the paths scattered through README and docs/INSTALL.md"]),
    Command("theme list [--json]", "list every scheme with its resolved tokens",
            example: "risk theme list --json", replaces: ["riskell --list-themes"]),
    Command("theme check [--json]", "check every scheme's contrast against its floors",
            example: "risk theme check", replaces: ["riskell --check-themes"]),
    Command("gestures status [--json]", "show which trackpad and dock keys fight riskell",
            example: "risk gestures status", replaces: ["riskell --gestures-fix (dry run)"]),
    Command("gestures fix [--restart-dock] [--dry-run] [--yes]", "save the originals, then turn the conflicting keys off",
            example: "risk gestures fix --yes", replaces: ["riskell --gestures-fix --yes", "riskell-setup --gestures riskell"]),
    Command("gestures restore [--dry-run] [--yes]", "put the saved key values back",
            example: "risk gestures restore", replaces: ["riskell --gestures-restore", "riskell-setup --restore-gestures"]),
    Command("wm status [--json]", "show which window manager is driving the rail",
            example: "risk wm status --json", replaces: ["risk wm"]),
    Command("wm export [--json]", "save each window's workspace number",
            example: "risk wm export", replaces: ["risk wm export"]),
    Command("wm import [--dry-run]", "put each saved window back on its number",
            example: "risk wm import --dry-run", replaces: ["risk wm import"]),
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
            ]),
    Command("completions <zsh|fish|bash>", "print the shell completions for this table",
            example: "risk completions zsh"),
    Command("version [--json]", "print riskell, kit and lockfile versions",
            example: "risk version --json", replaces: ["riskell --version", "riskell-setup --version"]),
    Command("help [command]", "print this table, or one command in detail",
            example: "risk help gestures", replaces: ["the header of scripts/risk"]),

    Command("fit [--scale N] [--panels] [--json]", "run pass/fail checks on each fake display",
            example: "risk fit --panels", tier: .experimental, replaces: ["riskell --check-fit", "riskell --check-panel"]),
    Command("snap [card] [--style S] [--out DIR] [--json]", "render pictures of bars, cards and the installer",
            example: "risk snap vol --out /tmp/p", tier: .experimental,
            replaces: ["riskell --snap", "riskell --pop", "scripts/overview-check", "scripts/make-previews", "scripts/make-screenshots"]),
    Command("wm start", "start omniwm and put each window on its number",
            example: "risk wm start", tier: .experimental, replaces: ["risk wm omniwm"]),
    Command("bench [cpu] [--runs N] [--json]", "measure idle cpu, memory and threads of a scratch instance",
            example: "risk bench cpu --runs 3", tier: .experimental, replaces: ["scripts/idle-cpu", "scripts/resource-check"]),
    Command("self-test [name] [--json]", "run the ci checks: installer, extensions, weather, usage",
            example: "risk self-test installer", tier: .experimental,
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
    return commandTable.compactMap { row in row.group == name ? row.subcommand.map { Child($0, row.summary) } : nil }
}
