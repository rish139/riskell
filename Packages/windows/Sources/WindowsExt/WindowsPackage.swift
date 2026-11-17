// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Rishabh Tiwari

import RiskellKit

/// What riskell links in: the workspace rail with its window card, and the focused application's icon. They share the window manager's
/// model (`WindowsModel`) and its actions (`KitHost.windows`).
public enum WindowsPackage: RiskellPackage {
    public static var atoms: [any CustomAtom.Type] { [WorkspacesAtom.self, AppIconAtom.self] }
}
