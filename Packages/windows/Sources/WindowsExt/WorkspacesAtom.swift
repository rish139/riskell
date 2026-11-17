// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Rishabh Tiwari

import SwiftUI
import RiskellKit

/// The workspace rail and its window card. The rail is one bead per space; the card lists the spaces and their windows.
public struct WorkspacesAtom: CustomAtom {
    /// The horizontal form is one 28 pt slot per space: 336 pt fits twelve spaces.
    public static let meta = AtomMeta(id: "workspaces", name: "Workspaces", priority: 8, maxWidth: 336)
    public init() {}
    public func horizontal(_ env: Env) -> some View { WorkspacesFace(vertical: false) }
    public func vertical(_ env: Env) -> some View { WorkspacesFace(vertical: true) }
    public var card: Card? {
        Card(id: "workspaces", size: { _ in let l = WsLayout.current(); return CGSize(width: l.width, height: l.height) }) { WorkspacesCard() }
    }
    public func isBlank(_ env: Env) -> Bool { WindowsModel.shared.spaces.isEmpty }
}
