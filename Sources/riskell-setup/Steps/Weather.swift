import Foundation

/// The weather location: a text input, one lookup after 400 ms of quiet, and the results as options.
extension App {
    func drawWeather(_ g: Grid, _ b: Body) {
        var y = Chrome.title(g, b, "Weather location", "Only the city you type is sent, to open-meteo.com.")
        let w = min(b.w, 60)
        if manual {
            g.put(b.x, y, "coordinates", Ink.dim)
            g.put(b.x + 13, y, "›", Ink.accentText)
            g.put(b.x + 15, y, manualText, Ink.bold, max: w - 15)
            g.put(b.x + 15 + min(manualText.count, w - 16), y, "▏", Ink.accentText)
        } else {
            g.put(b.x, y, "›", Ink.accentText)
            g.put(b.x + 2, y, query, Ink.bold, max: w - 2)
            g.put(b.x + 2 + min(query.count, w - 3), y, "▏", Ink.accentText)
            if query.isEmpty { g.put(b.x + 2, y, "type a city", Ink.dim) }
        }
        y += 2
        if !manual {
            if geoSearching || geoPending != nil {
                let spin = spinnerFrames[tickCount % spinnerFrames.count]
                g.put(b.x, y, "\(spin) looking up", Ink.dim)
            } else if case .offline(let why)? = geoOutcome {
                g.put(b.x, y, "!", Ink.accentText)
                Chrome.paragraph(g, b.x + 2, y, width: b.w - 2, text: "\(why). Enter coordinates by hand, or skip.")
                y += 1
            } else if case .noMatch? = geoOutcome {
                g.put(b.x, y, "no city by that name", Ink.dim)
            }
        } else {
            g.put(b.x, y, "two numbers, latitude then longitude, like 53.55, 10.00", Ink.dim, max: w)
        }
        y += 2
        if manual { return }
        let rows = weatherRows
        for (i, r) in rows.enumerated() where y + i < b.y + b.h {
            let focused = cursor == i
            switch r {
            case .place(let p):
                Chrome.option(g, b.x, y, width: w, label: p.name, selected: c.weather == p, focused: focused, note: p.region)
            case .keep(let p):
                Chrome.option(g, b.x, y, width: w, label: "Keep \(p.name)", selected: true, focused: focused, note: "current")
            case .manual:
                Chrome.option(g, b.x, y, width: w, label: "Enter coordinates by hand", selected: false, focused: focused)
            case .skip:
                Chrome.option(g, b.x, y, width: w, label: "Skip", selected: c.weather == nil, focused: focused, note: "no weather")
            }
            y += 1
        }
    }
}
