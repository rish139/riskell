// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright 2026 Rishabh Tiwari

import RiskellKit

/// What riskell links in: dwindle tiling for AeroSpace. It has no place on a bar, so it is one behaviour and no atoms.
public enum DwindlePackage: RiskellPackage {
    public static var behaviours: [any Behaviour.Type] { [Dwindle.self] }
}
