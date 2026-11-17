// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Rishabh Tiwari

import SwiftUI
import RiskellKit

/// What riskell links in: one atom, the clock.
public enum ClockPackage: RiskellPackage {
    public static var atoms: [any CustomAtom.Type] { [ClockAtom.self] }
}

/// The time, in one object for both forms of the atom and the card. `minute` changes once a minute (the digits and the date redraw then);
/// `seconds` has its own object, so the once-a-second tick redraws only the drain. It ticks only while the atom is on a showing bar.
final class ClockModel: ObservableObject {
    static let shared = ClockModel()
    @Published private(set) var minute = Date()
    let seconds = ClockSeconds()
    private static let cal = Calendar.current
    func tick() {
        let now = Date()
        seconds.set(Self.cal.component(.second, from: now))
        if !Self.cal.isDate(now, equalTo: minute, toGranularity: .minute) { minute = now }
    }
}

final class ClockSeconds: ObservableObject {
    @Published private(set) var second = Calendar.current.component(.second, from: Date())
    func set(_ s: Int) { if s != second { second = s } }
}

public struct ClockAtom: CustomAtom {
    public static let meta = AtomMeta(id: "clock", name: "Clock", priority: 9, maxWidth: 200)
    public init() {}
    public func horizontal(_ env: Env) -> some View { ClockFace(vertical: false) }
    public func vertical(_ env: Env) -> some View { ClockFace(vertical: true) }
    public var card: Card? { Card(id: "date", size: { DateCard.size(stage: $0) }) { DateCard() } }
    public func activate(_ env: Env) -> (() -> Void)? {
        ClockModel.shared.tick()
        return env.repeating(.seconds(1)) { ClockModel.shared.tick() }
    }
}
