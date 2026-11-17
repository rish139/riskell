// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Rishabh Tiwari

import SwiftUI
import RiskellKit

/// What the package exports: the network atom.
public enum NetworkPackage: RiskellPackage {
    public static var atoms: [any CustomAtom.Type] { [NetAtom.self] }
}

/// The network atom: the link glyph, the four signal cells and the exact figure, in both forms, and the network card on hover. The Wi-Fi
/// service runs only while this atom is on a showing bar; the card's live readings run only while the card is open.
public struct NetAtom: CustomAtom {
    public static let meta = AtomMeta(id: "net", name: "Network", priority: 4, maxWidth: 120)
    public init() {}
    public func horizontal(_ env: Env) -> some View { NetFace(vertical: false) }
    public func vertical(_ env: Env) -> some View { NetFace(vertical: true) }
    public var card: Card? { Card(id: "net", size: { _ in NetworkCard.size }) { NetworkCard() } }
    public func activate(_ env: Env) -> (() -> Void)? {
        NetEnv.env = env
        let wifi = Wifi.shared
        wifi.start()
        return { wifi.stop() }
    }
}
