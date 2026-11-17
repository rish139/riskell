// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Rishabh Tiwari

import Darwin
import SwiftUI
import RiskellKit

/// The package: what riskell links in. Two atoms, to show both kinds.
public enum LoadPackage: RiskellPackage {
    public static var readings: [any ReadingAtom.Type] { [Load.self] }
    public static var atoms: [any CustomAtom.Type] { [Pulse.self] }
}

private func loadAverages() -> [Double] {
    var l = [Double](repeating: 0, count: 3)
    return getloadavg(&l, 3) == 3 ? l : [0, 0, 0]
}

/// A reading atom: the kit draws the row, the column and the card. Only the numbers are ours.
public struct Load: ReadingAtom {
    public static let meta = AtomMeta(id: "load", name: "Load average", priority: 4, maxWidth: 320)
    public init() {}
    public func readings(_ env: Env) -> AsyncStream<Reading?> {
        // settings declared in riskell.json, changed in riskell preferences
        let hotAt = env.prefs.number("hotAt", default: 100) / 100, icon = env.prefs.bool("icon", default: true)
        return env.every(.seconds(5)) {
            let l = loadAverages(), cores = Double(ProcessInfo.processInfo.activeProcessorCount)
            let busy = min(1, l[0] / (cores * hotAt))
            return Reading(text: String(format: "%.2f", l[0]), icon: icon ? "gauge.with.dots.needle.33percent" : nil, tone: .heat(busy), value: busy,
                           lines: [String(format: "1 min   %.2f", l[0]), String(format: "5 min   %.2f", l[1]), String(format: "15 min  %.2f", l[2])],
                           values: [Metric(label: "5M", text: String(format: "%.1f", l[1])), Metric(label: "15M", text: String(format: "%.1f", l[2]))])
        }
    }
}

/// A custom atom: our own drawing, both forms, a card. It owns a small model that runs only while the atom is on a bar.
public struct Pulse: CustomAtom {
    public static let meta = AtomMeta(id: "pulse", name: "Load pulse", priority: 3, maxWidth: 120)
    public init() {}
    private let model = PulseModel()

    public func activate(_ env: Env) -> (() -> Void)? { env.repeating(.seconds(3)) { [model] in model.tick() } }

    public func horizontal(_ env: Env) -> some View { PulseRow(model: model) }
    public func vertical(_ env: Env) -> some View { PulseColumn(model: model) }
    public var card: Card? { Card(id: "pulse", size: { _ in CGSize(width: 220, height: 96) }) { PulseCard(model: model) } }
}

final class PulseModel: ObservableObject {
    @Published var load = 0.0
    func tick() {
        let v = min(1, loadAverages()[0] / Double(ProcessInfo.processInfo.activeProcessorCount))
        if v != load { load = v }
    }
}

struct PulseRow: View {
    @ObservedObject var model: PulseModel
    @State private var hot = false
    var body: some View {
        HStack(spacing: T.gap) {
            Cap(text: "LOAD", hot: hot)
            Bar(value: model.load, tone: Pal.heat(model.load), hot: hot, width: 44)
            Num(value: "\(Int(model.load * 100))", unit: "%", tone: Pal.heat(model.load), hot: hot)
        }
        .frame(height: G.pill)
        .popout("pulse", edge: .below, hot: $hot)
    }
}

struct PulseColumn: View {
    @ObservedObject var model: PulseModel
    @State private var hot = false
    var body: some View {
        VStack(spacing: 3) {
            Cap(text: "LOAD", hot: hot)
            VGauge(value: model.load, tone: Pal.heat(model.load), hot: hot, length: 34)
            Num(value: "\(Int(model.load * 100))", unit: nil, tone: Pal.heat(model.load), hot: hot)
        }
        .fixedSize()
        .frame(width: 40)
        .popout("pulse", edge: .right, hot: $hot)
    }
}

struct PulseCard: View {
    @ObservedObject var model: PulseModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Cap(text: "LOAD PULSE")
            Bar(value: model.load, tone: Pal.heat(model.load), hot: false, width: 190)
            Text("\(Int(model.load * 100)) % of all cores busy").font(T.sub).foregroundStyle(Pal.text2)
        }
        .padding(15)
        .frame(width: 220, height: 96, alignment: .topLeading)
    }
}
