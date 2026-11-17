import Foundation

/// The screens, in flow order. `welcome` is not counted in the step indicator.
enum Stage: Int, CaseIterable {
    case welcome, wm, bars, theme, weather, usage, gestures, scale, review, diff, install, finish

    /// The step number shown as "n / 8" (1 to 8), or nil for screens outside the count.
    var step: Int? {
        switch self {
        case .wm: return 1
        case .bars: return 2
        case .theme: return 3
        case .weather: return 4
        case .usage: return 5
        case .gestures: return 6
        case .scale: return 7
        case .review, .diff: return 8
        default: return nil
        }
    }
}

/// Every answer the user can give. Defaults come from the existing config.json, so a second run keeps what was chosen.
struct Choices {
    var wm = 0
    var preset: Preset = .classic
    var barMode: BarMode = .preset
    var cards: CardStyle = .flush
    var theme = 0
    var weather: Place?
    var claude = false
    var gesturesRiskell = false
    var gesturesFix = false
    var scale: Double?
    var replaceLayout = false

    static let wmIDs = ["auto", "omniwm", "yabai", "aerospace", "command", "none"]
    static let wmLabels = ["Auto", "OmniWM", "yabai", "AeroSpace", "Custom commands", "None"]
    static let wmNotes = [
        "follows what is running",
        "rail and gap reservation",
        "experimental, tiles with yabai",
        "experimental, unverified",
        "your own scripts, see docs/WM-COMMAND.md",
        "no workspaces; bars float over windows",
    ]

    /// Starts from the existing config: what was chosen last time is what is selected now.
    static func from(_ existing: [String: Any]?, themes: [SchemeData]) -> Choices {
        var c = Choices()
        guard let e = existing else {
            c.theme = themes.firstIndex(where: { $0.isDefault }) ?? 0
            return c
        }
        if let wm = e["wm"] as? String, let i = wmIDs.firstIndex(of: wm) { c.wm = i }
        if let t = e["theme"] as? String, let i = themes.firstIndex(where: { $0.id == t }) {
            c.theme = i
        } else {
            c.theme = themes.firstIndex(where: { $0.isDefault }) ?? 0
        }
        if let s = e["scale"] as? Double { c.scale = s }
        c.gesturesRiskell = (e["gestures"] as? String) == "riskell"
        if let loc = e["location"] as? [String: Any], let lat = loc["lat"] as? Double, let lon = loc["lon"] as? Double {
            c.weather = Place(name: (loc["name"] as? String) ?? "\(lat), \(lon)", region: "", lat: lat, lon: lon)
        }
        if let usage = e["usage"] as? [String: Any] {
            c.claude = (usage["claude"] as? Bool) ?? false
        }
        return c
    }

    var wmID: String { Choices.wmIDs[wm] }
    var themeData: SchemeData { schemeData[theme] }
}

enum StepStatus: Equatable { case pending, running, done, skipped, failed }

/// The install screen's model, updated from JobEvent messages on the main thread.
struct JobView {
    var names = stepNames
    var status: [StepStatus] = Array(repeating: .pending, count: stepNames.count)
    var details: [String] = Array(repeating: "", count: stepNames.count)
    var logLast: String = ""
    var failMessage: String?
    var failTail: [String] = []
    var summary: [String] = []
    var finished = false

    var progress: Double {
        let settled = status.filter { $0 == .done || $0 == .skipped }.count
        let running = status.contains(.running) ? 0.5 : 0
        return (Double(settled) + running) / Double(status.count)
    }

    mutating func apply(_ e: JobEvent) {
        switch e {
        case .stepStart(let i): status[i] = .running
        case .stepLog(_, let s): logLast = s
        case .stepDone(let i, let d): status[i] = .done; details[i] = d; logLast = ""
        case .stepSkipped(let i, let d): status[i] = .skipped; details[i] = d; logLast = ""
        case .failed(let i, let m, let tail): status[i] = .failed; failMessage = m; failTail = tail; details[i] = m
        case .finished(let lines): finished = true; summary = lines
        }
    }
}

enum BuildState: Equatable {
    case idle
    case running(String)
    case done(Double)
    case failed([String])
    case skipped(String)
}

enum WeatherRow {
    case place(Place), keep(Place), manual, skip
}

final class App {
    var facts: Facts
    let paths: Paths
    var repo: URL?
    var stage: Stage = .welcome
    var c: Choices
    var cursor = 0
    var notice: String?
    var noticeIsError = false
    var build: BuildState = .idle
    var builder: Builder?
    var noBuild = false
    var noLaunch = false
    var noPath = false
    /// --dry-run in the TUI: the Install action shows the plan and writes nothing.
    var dryRun = false
    var job: JobView?
    var jobPlan: Plan?
    var quit = false

    // weather
    var query = ""
    var manualText = ""
    var manual = false
    var geoSeq = 0
    var geoPending: Date?
    var geoSearching = false
    var geoOutcome: GeoOutcome?
    var places: [Place] = []

    // motion: all of it advances on tick(), which the loop calls only while something is animating
    var tickCount = 0
    var checksShown = 0
    var linesShown = 0
    var progressShown = 0.0
    var slideDir = 0
    var slideLeft = 0
    /// Frames left in which the newly chosen row shows its half-filled marker.
    var markerFrames = 0
    var conflicts: [String]?

    init(facts: Facts, paths: Paths, repo: URL?) {
        self.facts = facts
        self.paths = paths
        self.repo = repo
        self.c = Choices.from(facts.existing, themes: schemeData)
    }

    // MARK: rows

    /// The rows the current screen's cursor moves over.
    var rowCount: Int {
        switch stage {
        case .wm: return Choices.wmIDs.count
        case .bars: return 5
        case .theme: return schemeData.count
        case .weather: return weatherRows.count
        case .usage: return 1
        case .gestures: return c.gesturesRiskell ? 3 : 2
        case .scale: return 2
        case .review: return (facts.layoutFound ? 1 : 0) + 3
        default: return 1
        }
    }

    var weatherRows: [WeatherRow] {
        var rows: [WeatherRow] = places.map { .place($0) }
        if places.isEmpty, let w = c.weather, query.isEmpty, !manual { rows.append(.keep(w)) }
        if isOffline { rows.append(.manual) }
        rows.append(.skip)
        return rows
    }

    private var isOffline: Bool {
        if case .offline? = geoOutcome { return true }
        return false
    }

    // MARK: flow

    func go(_ next: Stage, dir: Int = 1) {
        stage = next
        cursor = startCursor(next)
        notice = nil
        slideDir = dir
        slideLeft = 3
        if next == .gestures, c.gesturesRiskell, conflicts == nil {
            conflicts = Detect.gestureConflicts()
        }
        if next == .finish { linesShown = 0 }
        if next == .welcome { checksShown = 0 }
    }

    private func startCursor(_ s: Stage) -> Int {
        switch s {
        case .wm: return c.wm
        case .bars: return c.preset.rawValue
        case .theme: return c.theme
        case .scale: return c.scale == nil ? 0 : 1
        case .gestures: return c.gesturesRiskell ? 1 : 0
        case .review: return 0
        default: return 0
        }
    }

    func back() {
        switch stage {
        case .welcome: quit = true
        case .wm: go(.welcome, dir: -1)
        case .bars: go(.wm, dir: -1)
        case .theme: go(.bars, dir: -1)
        case .weather: go(.theme, dir: -1)
        case .usage: go(.weather, dir: -1)
        case .gestures: go(.usage, dir: -1)
        case .scale: go(.gestures, dir: -1)
        case .review: go(.scale, dir: -1)
        case .diff: go(.review, dir: -1)
        case .install:
            if job?.finished == true { return }
            if job?.failMessage != nil { go(.review, dir: -1) }
        case .finish: quit = true
        }
    }

    /// Leaving the welcome screen starts the build in the background, while the questions are answered.
    func startBuild() {
        guard let repo = repo else { build = .skipped("no repository found"); return }
        if noBuild { build = .skipped("skipped (--no-build)"); return }
        if Detect.buildIsFresh(repo) { build = .skipped("the binary is current"); return }
        let b = Builder()
        builder = b
        build = .running("")
        b.start(repo: repo) { line in Wake.post(.buildLine(line)) }
        DispatchQueue.global().async {
            b.wait()
            Wake.post(.buildDone(ok: b.ok, detail: b.ok ? String(format: "%.0f", b.seconds) : b.tail.joined(separator: "\n")))
        }
    }

    // MARK: plan

    func plan() -> Plan {
        let repoURL = repo ?? URL(fileURLWithPath: ".")
        var owned: [(String, Any?)] = []
        owned.append(("wm", c.wmID))
        owned.append(("theme", c.themeData.id))
        if let w = c.weather {
            let r = { (x: Double) in (x * 10000).rounded() / 10000 }
            owned.append(("location", ["name": w.name, "lat": r(w.lat), "lon": r(w.lon)] as [String: Any]))
        } else {
            owned.append(("location", nil))
        }
        // Only usage.claude is the installer's; the other usage keys (the optional token limits, an old opencode block) stay as they were.
        var usage = (facts.existing?["usage"] as? [String: Any]) ?? [:]
        if c.claude { usage["claude"] = true } else { usage.removeValue(forKey: "claude") }
        let usageValue: Any? = usage.isEmpty ? nil : usage
        owned.append(("usage", usageValue))
        owned.append(("gestures", c.gesturesRiskell ? "riskell" : "system"))
        owned.append(("scale", c.scale.map { $0 as Any }))
        var layoutText: String?
        var layoutLabel = "kept your layout.json"
        if !facts.layoutFound || c.replaceLayout {
            let layout = Presets.layout(c.preset, mode: c.barMode, cards: c.cards)
            layoutText = try? Presets.json(layout)
            layoutLabel = "\(c.preset.label) layout written"
        }
        return Plan(paths: paths, repo: repoURL, agentLabel: facts.agentLabel, owned: owned, layoutText: layoutText,
                    layoutLabel: layoutLabel, gesturesFix: c.gesturesRiskell && c.gesturesFix, noLaunch: noLaunch, noBuild: noBuild,
                    addPath: !noPath && !Detect.linkDir(paths).onPath)
    }

    func startInstall() {
        let p = plan()
        jobPlan = p
        job = JobView()
        stage = .install
        cursor = 0
        let b = builder
        DispatchQueue.global().async {
            Installer.run(p, builder: b) { Wake.post(.job($0)) }
        }
    }

    // MARK: input

    func key(_ k: Key) {
        if k == .interrupt { quit = true; return }
        notice = nil
        noticeIsError = false
        switch stage {
        case .welcome: welcomeKey(k)
        case .wm, .theme: listKey(k)
        case .bars: barsKey(k)
        case .weather: weatherKey(k)
        case .usage: usageKey(k)
        case .gestures: gesturesKey(k)
        case .scale: scaleKey(k)
        case .review: reviewKey(k)
        case .diff:
            if k == .esc || k == .enter { go(.review, dir: -1) }
        case .install: installKey(k)
        case .finish:
            if k == .enter || k == .char("q") || k == .esc { quit = true }
        }
    }

    private func moveCursor(_ k: Key) -> Bool {
        switch k {
        case .up: cursor = max(0, cursor - 1); markerFrames = 2; return true
        case .down: cursor = min(rowCount - 1, cursor + 1); markerFrames = 2; return true
        default: return false
        }
    }

    private func welcomeKey(_ k: Key) {
        switch k {
        case .enter:
            if facts.blocked {
                notice = "Swift is needed to build riskell: run xcode-select --install, then start setup again."
                noticeIsError = true
                return
            }
            startBuild()
            go(.wm)
        case .esc, .char("q"): quit = true
        default: break
        }
    }

    private func listKey(_ k: Key) {
        if moveCursor(k) {
            if stage == .wm { c.wm = cursor }
            if stage == .theme { c.theme = cursor }
            return
        }
        switch k {
        case .enter:
            if stage == .wm { c.wm = cursor }
            if stage == .theme { c.theme = cursor }
            go(stage == .wm ? .bars : .weather)
        case .esc: back()
        case .char("q"): quit = true
        default: break
        }
    }

    private func barsKey(_ k: Key) {
        if moveCursor(k) {
            if cursor < 3 { c.preset = Preset(rawValue: cursor) ?? .classic }
            return
        }
        switch k {
        case .enter: go(.theme)
        case .esc: back()
        case .char("q"): quit = true
        case .left, .right, .char(" "):
            if cursor == 3 {
                c.cards = c.cards == .flush ? .chat : .flush
            } else if cursor == 4 {
                let step = k == .left ? 2 : 1
                c.barMode = BarMode(rawValue: (c.barMode.rawValue + step) % 3) ?? .preset
            }
        default: break
        }
    }

    private func weatherKey(_ k: Key) {
        let rows = weatherRows
        if k == .up || k == .down { _ = moveCursor(k); return }
        switch k {
        case .char(let s) where !s.isEmpty && s != "\n":
            if manual { manualText += s } else { query += s; geoChanged() }
            cursor = 0
        case .backspace:
            if manual { if !manualText.isEmpty { manualText.removeLast() } } else if !query.isEmpty { query.removeLast(); geoChanged() }
        case .enter:
            if manual {
                guard let (lat, lon) = Geocode.parseCoordinates(manualText) else {
                    notice = "type two numbers, latitude then longitude, like 53.55, 10.00"
                    noticeIsError = true
                    return
                }
                c.weather = Place(name: "\(lat), \(lon)", region: "", lat: lat, lon: lon)
                manual = false
                go(.usage)
                return
            }
            guard cursor < rows.count else { return }
            switch rows[cursor] {
            case .place(let p), .keep(let p): c.weather = p; go(.usage)
            case .manual: manual = true; manualText = ""
            case .skip: c.weather = nil; go(.usage)
            }
        case .esc:
            if manual { manual = false } else { back() }
        default: break
        }
    }

    /// The text changed: the lookup waits 400 ms for the typing to stop, then runs once (see `tick`).
    private func geoChanged() {
        geoSeq += 1
        geoOutcome = nil
        places = []
        geoPending = query.trimmingCharacters(in: .whitespaces).isEmpty ? nil : Date().addingTimeInterval(0.4)
        geoSearching = false
    }

    private func usageKey(_ k: Key) {
        if moveCursor(k) { return }
        switch k {
        case .enter: go(.gestures)
        case .esc: back()
        case .char(" "), .left, .right: c.claude.toggle()
        case .char("q"): quit = true
        default: break
        }
    }

    private func gesturesKey(_ k: Key) {
        if moveCursor(k) {
            if cursor < 2 { c.gesturesRiskell = cursor == 1 }
            if c.gesturesRiskell, conflicts == nil { conflicts = Detect.gestureConflicts() }
            return
        }
        switch k {
        case .enter:
            if cursor < 2 { c.gesturesRiskell = cursor == 1 }
            go(.scale)
        case .char(" "):
            if cursor == 2 { c.gesturesFix.toggle() }
        case .esc: back()
        case .char("q"): quit = true
        default: break
        }
    }

    private func scaleKey(_ k: Key) {
        if moveCursor(k) {
            c.scale = cursor == 1 ? (c.scale ?? 1.0) : nil
            return
        }
        switch k {
        case .left, .right:
            guard cursor == 1 else { return }
            let s = (c.scale ?? 1.0) + (k == .right ? 0.05 : -0.05)
            c.scale = min(2.0, max(0.5, (s * 100).rounded() / 100))
        case .enter: go(.review)
        case .esc: back()
        case .char("q"): quit = true
        default: break
        }
    }

    private func reviewKey(_ k: Key) {
        let layoutRow = facts.layoutFound ? 0 : -1
        if moveCursor(k) { return }
        if cursor == layoutRow, k == .char(" ") || k == .left || k == .right {
            c.replaceLayout.toggle()
            return
        }
        let action = cursor - (facts.layoutFound ? 1 : 0)
        switch k {
        case .enter:
            switch action {
            case 0:
                if dryRun { go(.diff) } else { startInstall() }
            case 1: go(.diff)
            case 2: back()
            default: break
            }
        case .esc: back()
        case .char("q"): quit = true
        default: break
        }
    }

    private func installKey(_ k: Key) {
        guard let j = job else { return }
        if j.finished {
            if k == .enter || k == .char("q") { go(.finish) }
            return
        }
        if j.failMessage != nil {
            if k == .enter {
                job = JobView()
                if let p = jobPlan {
                    let b = builder
                    DispatchQueue.global().async { Installer.run(p, builder: b) { Wake.post(.job($0)) } }
                }
            } else if k == .esc || k == .char("q") {
                if k == .char("q") { quit = true } else { go(.review, dir: -1) }
            }
        }
    }

    // MARK: messages from background work

    func handle(_ m: Message) {
        switch m {
        case .key(let k): key(k)
        case .resize: break
        case .buildLine(let s):
            if case .running = build { build = .running(s) }
        case .buildDone(let ok, let detail):
            if ok { build = .done(Double(detail) ?? 0) } else { build = .failed(detail.split(separator: "\n").map(String.init)) }
        case .geo(let seq, let outcome):
            guard seq == geoSeq else { return }
            geoSearching = false
            geoOutcome = outcome
            if case .found(let list) = outcome { places = list }
            cursor = 0
        case .job(let e):
            job?.apply(e)
            if case .finished = e { go(.finish) }
        }
    }

    // MARK: time

    /// Something is moving: the loop wakes every 40 ms (reveals) or 100 ms (spinner, progress), otherwise it blocks.
    var timeoutMs: Int32? {
        if revealing { return stage == .welcome ? 60 : 40 }
        if isBusy { return 100 }
        return nil
    }

    var revealing: Bool {
        (stage == .welcome && checksShown < Detect.checks(facts).count)
            || (stage == .finish && linesShown < (job?.summary.count ?? 0) + 2)
    }

    var isBusy: Bool {
        if case .running = build { return true }
        if geoPending != nil || geoSearching { return true }
        if let j = job, !j.finished, j.failMessage == nil { return true }
        if slideLeft > 0 || markerFrames > 0 { return true }
        if let j = job, abs(j.progress - progressShown) > 0.001 { return true }
        return false
    }

    func tick() {
        tickCount += 1
        if stage == .welcome, checksShown < Detect.checks(facts).count { checksShown += 1 }
        if stage == .finish, let j = job, linesShown < j.summary.count + 2 { linesShown += 1 }
        if slideLeft > 0 { slideLeft -= 1 }
        if markerFrames > 0 { markerFrames -= 1 }
        if let j = job {
            progressShown += (j.progress - progressShown) * 0.4
            if abs(j.progress - progressShown) < 0.01 { progressShown = j.progress }
        }
        if let due = geoPending, Date() >= due {
            geoPending = nil
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                geoSearching = true
                let seq = geoSeq, q = query
                DispatchQueue.global().async { Wake.post(.geo(seq: seq, outcome: Geocode.search(q))) }
            }
        }
    }
}
