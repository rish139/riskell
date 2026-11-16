import Foundation

let riskellVersion = "1.0"
let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
let progressCells: [String] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]

extension App {
    /// Builds the frame for the current state. Pure: the same state always gives the same grid (snapshots rely on it).
    func render(w: Int, h: Int) -> Grid {
        let g = Grid(w: w, h: h)
        Ease.marker = markerFrames > 0
        if w < Chrome.minW || h < Chrome.minH {
            g.put(0, 0, "riskell setup needs a terminal of at least \(Chrome.minW)x\(Chrome.minH); this one is \(w)x\(h). Make it bigger.", Ink.dim, max: w)
            return g
        }
        Chrome.drawHeader(g, stage: stage)
        let b = Chrome.body(g)
        // A slide between steps: the body is drawn at an offset that eases to zero over three frames.
        var status = statusLine()
        if let n = notice { status = (n, noticeIsError) }
        let hints = footerHints()
        let slideOffset = slideLeft > 0 ? slideDir * (slideLeft * b.w / 4) : 0
        if slideOffset != 0 {
            let inner = Grid(w: b.w, h: b.h)
            drawBody(inner, Body(x: 0, y: 0, w: b.w, h: b.h))
            for y in 0..<b.h {
                for x in 0..<b.w {
                    let sx = x - slideOffset
                    guard sx >= 0, sx < b.w else { continue }
                    g.set(b.x + x, b.y + y, inner[sx, y])
                }
            }
        } else {
            drawBody(g, b)
        }
        Chrome.drawFooter(g, hints: hints, status: status)
        return g
    }

    /// The bottom status line: a notice, else the build's progress while it runs.
    func statusLine() -> (String, Bool)? {
        switch build {
        case .running(let last):
            let spin = spinnerFrames[tickCount % spinnerFrames.count]
            let tail = last.isEmpty ? "starting" : last
            return ("\(spin)  building riskell   \(tail)", false)
        case .done(let s): return ("✓  riskell built in \(Int(s)) s", false)
        case .skipped(let why): return stage == .welcome ? nil : ("build \(why)", false)
        case .failed: return ("build failed: the last lines are in the install step", true)
        case .idle: return nil
        }
    }

    func footerHints() -> String {
        switch stage {
        case .welcome: return "⏎ start   q quit"
        case .wm, .theme: return "↑↓ move   ⏎ continue   esc back   q quit"
        case .bars: return "↑↓ move   ←→ change   ⏎ continue   esc back   q quit"
        case .weather:
            if manual { return "type lat, lon   ⏎ use it   esc back" }
            return "type a city   ↑↓ choose   ⏎ continue   esc back"
        case .usage: return "↑↓ move   space toggle   ⏎ continue   esc back"
        case .gestures: return "↑↓ move   space toggle   ⏎ continue   esc back   q quit"
        case .scale: return "↑↓ move   ←→ adjust   ⏎ continue   esc back"
        case .review: return "↑↓ move   space toggle   ⏎ choose   esc back"
        case .diff: return "⏎ or esc back"
        case .install:
            if let j = job, j.failMessage != nil { return "⏎ retry   esc review   q quit" }
            return (job?.finished ?? false) ? "⏎ continue" : "working..."
        case .finish: return "⏎ done   q quit"
        }
    }

    private func drawBody(_ g: Grid, _ b: Body) {
        switch stage {
        case .welcome: drawWelcome(g, b)
        case .wm: drawWM(g, b)
        case .bars: drawBars(g, b)
        case .theme: drawTheme(g, b)
        case .weather: drawWeather(g, b)
        case .usage: drawUsage(g, b)
        case .gestures: drawGestures(g, b)
        case .scale: drawScale(g, b)
        case .review: drawReview(g, b)
        case .diff: drawDiff(g, b)
        case .install: drawInstall(g, b)
        case .finish: drawFinish(g, b)
        }
    }
}
