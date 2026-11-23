import Foundation
import RiskellTTY

/// The weather location: a text field, one lookup after 400 ms of quiet, and the results as kit option rows.
extension App {
    func weatherLines(_ tty: Tty) -> [String] {
        var out = section(tty, "weather location")
        out.append(tty.field(manual ? "coords" : "city",
                             value: manual ? manualText : query,
                             focused: true,
                             placeholder: manual ? "53.55, 10.00" : "type a city"))
        out.append("")
        if manual {
            out += tty.paragraph("Two numbers, latitude then longitude, like 53.55, 10.00.")
            return out
        }
        if geoSearching || geoPending != nil {
            out += tty.paragraph("looking up...")
        } else if case .offline(let why)? = geoOutcome {
            out += tty.check(.warn, "lookup", "\(why). Enter coordinates by hand, or skip.", keyWidth: 7)
        } else if case .noMatch? = geoOutcome {
            out += tty.paragraph("No city by that name.")
        }
        out.append("")
        for (i, row) in weatherRows.enumerated() {
            let focused = cursor == i
            switch row {
            case .place(let p):
                out += tty.option(p.name, detail: p.region, selected: c.weather == p, focused: focused)
            case .keep(let p):
                out += tty.option("Keep \(p.name)", detail: "current", selected: true, focused: focused)
            case .manual:
                out += tty.option("Enter coordinates by hand", selected: false, focused: focused)
            case .skip:
                out += tty.option("Skip", detail: "no weather", selected: c.weather == nil, focused: focused)
            }
        }
        return out
    }
}
