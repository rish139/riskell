// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright 2026 Rishabh Tiwari

import RiskellKit

/// What the package exports: one atom, the volume, with its mixer card.
public enum VolumePackage: RiskellPackage {
    public static var atoms: [any CustomAtom.Type] { [VolAtom.self] }
}
