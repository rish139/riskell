// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Rishabh Tiwari

import SwiftUI
import RiskellKit

/// The fan atom: the status box, the rpm with its trace and the hottest sensor, and the thermal card on hover. The engine runs the SMC reads
/// only while it is on a showing bar.
public struct FanAtom: CustomAtom {
    public static let meta = AtomMeta(id: "fan", name: "Fan", priority: 3, maxWidth: 260)
    public init() {}
    public func horizontal(_ env: Env) -> some View { FanFace(vertical: false) }
    public func vertical(_ env: Env) -> some View { FanFace(vertical: true) }
    public var card: Card? { Card(id: "fan", size: { _ in FanCard.size }) { FanCard() } }
    public func activate(_ env: Env) -> (() -> Void)? { SystemEngine.shared.retainAll(env) }
}
