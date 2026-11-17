// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Rishabh Tiwari

import Combine
import Foundation

/// One Open-Meteo forecast, typed. Times are the location's own wall-clock strings ("2026-10-29T22:00"), exactly as the API sends them.
struct WX: Equatable, Codable {
    struct Cur: Equatable, Codable {
        var time = "", temp = 0.0, feels = 0.0, isDay = 1, code = 0
        var humidity: Double? = nil, precip: Double? = nil, cloud: Double? = nil, pressure: Double? = nil, uv: Double? = nil, dew: Double? = nil
        var visibility: Double? = nil, windSpeed: Double? = nil, windGusts: Double? = nil, windDir: Double? = nil
    }
    struct Hour: Equatable, Codable {
        var time = "", temp = 0.0, code = 0, isDay = 1
        var feels: Double? = nil, pop: Double? = nil, precip: Double? = nil, humidity: Double? = nil, cloud: Double? = nil, dew: Double? = nil
        var pressure: Double? = nil, wind: Double? = nil, visibility: Double? = nil, uv: Double? = nil
    }
    struct Day: Equatable, Codable, Identifiable {
        var id: String { date }
        var date = "", code = 0, max = 0.0, min = 0.0
        var feelsMax: Double? = nil, feelsMin: Double? = nil, pop: Double? = nil, precipSum: Double? = nil, precipHours: Double? = nil
        var sunrise = "", sunset = "", uv: Double? = nil, windMax: Double? = nil, gustMax: Double? = nil, windDir: Double? = nil
        var daylight: Double? = nil, sunshine: Double? = nil
    }
    struct AQ: Equatable, Codable { var usAqi: Double; var pm25: Double?; var pm10: Double? }
    var location = ""
    var cur = Cur()
    var hours: [Hour] = []          // 6 past hours + 16 days of forecast
    var days: [Day] = []            // 92 past days + 16 days of forecast
    var aqi: AQ? = nil
    var syncedAt = 0.0

    var todayKey: String { String(cur.time.prefix(10)) }
    /// today's row; when the payload has none, the envelope of the next twelve hours
    var envelope: (hi: Double, lo: Double)? {
        if let d = days.first(where: { $0.date == todayKey }) { return (d.max, d.min) }
        guard let i = nowIndex else { return nil }
        let w = hours[i..<min(hours.count, i + 12)].map(\.temp)
        return w.isEmpty ? nil : (w.max()!, w.min()!)
    }
    var nowIndex: Int? { hours.firstIndex { $0.time.prefix(13) == cur.time.prefix(13) } }
    /// the next six hours' precipitation probability, for the atom's pips
    var pips: [Double] { guard let i = nowIndex else { return [] }; return hours[i..<min(hours.count, i + 6)].map { $0.pop ?? 0 } }
}

/// The current forecast for the views. The service sets it; the atom and the card observe it.
final class WeatherState: ObservableObject {
    static let shared = WeatherState()
    @Published private(set) var wx: WX?
    func set(_ w: WX?) { if w != wx { wx = w } }
}
