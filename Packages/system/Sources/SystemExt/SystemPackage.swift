// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright 2026 Rishabh Tiwari

import RiskellKit

/// What riskell links in: battery, CPU and fans. They share one engine (`SystemEngine`) and the two model objects, because their cards
/// read each other's numbers (the CPU card shows the battery and temperatures, the fan card the CPU load and the battery).
public enum SystemPackage: RiskellPackage {
    public static var atoms: [any CustomAtom.Type] { [BatAtom.self, CpuAtom.self, FanAtom.self] }
}
