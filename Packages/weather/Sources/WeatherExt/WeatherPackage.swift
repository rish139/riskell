// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright 2026 Rishabh Tiwari

import Combine
import SwiftUI
import RiskellKit

/// What the package exports: one atom, the weather.
public enum WeatherPackage: RiskellPackage {
    public static var atoms: [any CustomAtom.Type] { [WeatherAtom.self] }
}

/// The condition and the temperature, and a card with today, the next 24 hours and the next 14 days. The forecast is fetched only while the
/// atom is on a showing bar, every 10 minutes, and again when the place in config.json changes.
public struct WeatherAtom: CustomAtom {
    public static let meta = AtomMeta(id: "weather", name: "Weather", priority: 2, maxWidth: 260)
    public init() {}
    public func horizontal(_ env: Env) -> some View { WeatherFace(vertical: false) }
    public func vertical(_ env: Env) -> some View { WeatherFace(vertical: true) }
    public var card: Card? { Card(id: "weather", size: { _ in WeatherCard.size }) { WeatherCard() } }
    public func activate(_ env: Env) -> (() -> Void)? {
        let service = WeatherService(env: env)
        // A move in config.json (the three values that name the place) starts over; other config keys are not a move. The first value is the
        // starting point, so it is dropped; the repeating timer below does the first fetch.
        let moved = env.config.$json.receive(on: DispatchQueue.main).map { _ in service.spot }
            .removeDuplicates().dropFirst()
            .sink { _ in service.reconfigure() }
        let stopRepeat = env.repeating(.seconds(600)) { service.tick() }
        return { moved.cancel(); stopRepeat() }
    }
}
