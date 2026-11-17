// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Rishabh Tiwari

import SwiftUI
import RiskellKit

/// The focused window's application icon (and, on a horizontal bar, its name). Blank while no window is focused.
public struct AppIconAtom: CustomAtom {
    public static let meta = AtomMeta(id: "appicon", name: "App icon", priority: 6, maxWidth: 260)
    public init() {}
    public func horizontal(_ env: Env) -> some View { AppIconFace(vertical: false) }
    public func vertical(_ env: Env) -> some View { AppIconFace(vertical: true) }
    public func isBlank(_ env: Env) -> Bool { !WindowsModel.shared.windows.contains(where: { $0.focused }) }
}
