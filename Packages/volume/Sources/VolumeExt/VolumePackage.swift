// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Rishabh Tiwari

import RiskellKit

/// What the package exports: one atom, the volume, with its mixer card.
public enum VolumePackage: RiskellPackage {
    public static var atoms: [any CustomAtom.Type] { [VolAtom.self] }
}
