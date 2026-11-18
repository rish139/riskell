// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright 2026 Rishabh Tiwari

import RiskellKit

/// What riskell links in: the workspace rail with its window card, and the focused application's icon. They share the window manager's
/// model (`WindowsModel`) and its actions (`KitHost.windows`).
public enum WindowsPackage: RiskellPackage {
    public static var atoms: [any CustomAtom.Type] { [WorkspacesAtom.self, AppIconAtom.self] }
}
