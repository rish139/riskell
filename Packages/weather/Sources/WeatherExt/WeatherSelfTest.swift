// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright 2026 Rishabh Tiwari

import Foundation
import RiskellKit

/// `riskell --weather-selftest`: builds a forecast like Open-Meteo's (390 hours, 108 days, every column the app reads), parses it with the current
/// parser and with the first version, checks both give the same result, and reports the time of each. The app draws the cases.
public enum WeatherSelfTest {
    public static func cases() -> [(name: String, ok: Bool, detail: String?)] {
        let hours = 390, days = 108
        func col(_ n: Int, _ f: (Int) -> Any) -> [Any] { (0..<n).map(f) }
        var hourly: [String: Any] = ["time": col(hours) { "2026-11-\(String(format: "%02d", $0 / 24 % 28 + 1))T\(String(format: "%02d", $0 % 24)):00" }]
        for k in ["temperature_2m", "apparent_temperature", "precipitation_probability", "precipitation", "relative_humidity_2m", "cloud_cover", "dew_point_2m", "pressure_msl", "wind_speed_10m", "visibility", "uv_index"] {
            hourly[k] = col(hours) { Double($0 % 37) * 0.7 + 1 }
        }
        hourly["weather_code"] = col(hours) { $0 % 4 }; hourly["is_day"] = col(hours) { $0 % 24 > 6 && $0 % 24 < 19 ? 1 : 0 }
        var daily: [String: Any] = ["time": col(days) { "2026-0\($0 % 9 + 1)-1\($0 % 9)" }, "sunrise": col(days) { _ in "2026-11-16T07:41" }, "sunset": col(days) { _ in "2026-11-16T16:03" }]
        for k in ["weather_code", "temperature_2m_max", "temperature_2m_min", "apparent_temperature_max", "apparent_temperature_min", "precipitation_probability_max", "precipitation_sum", "precipitation_hours", "uv_index_max", "wind_speed_10m_max", "wind_gusts_10m_max", "wind_direction_10m_dominant", "daylight_duration", "sunshine_duration"] {
            daily[k] = col(days) { Double($0 % 23) * 1.3 }
        }
        let json: [String: Any] = ["current": ["time": "2026-11-16T14:00", "temperature_2m": 12.3, "apparent_temperature": 8.9, "is_day": 1, "weather_code": 3, "relative_humidity_2m": 70.0], "hourly": hourly, "daily": daily]
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return [("build the sample forecast", false, nil)] }
        func time(_ f: (Data) -> WX?) -> (WX?, Double) { let t = DispatchTime.now().uptimeNanoseconds; let r = f(data); return (r, Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6) }
        _ = time(WeatherService.parse)      // warm up
        let (a, ta) = time(WeatherService.parse), (b, tb) = time(WeatherService.parseReference)
        let same = a != nil && a == b
        return [("fast parse", a != nil, "\(String(format: "%.1f", ta)) ms, \(a?.hours.count ?? 0) hours, \(a?.days.count ?? 0) days"),
                ("reference parse", b != nil, "\(String(format: "%.1f", tb)) ms"),
                ("identical results", same, nil)]
    }
}
