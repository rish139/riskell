import Foundation
import RiskellKit

/// Open-Meteo: ONE forecast request feeds everything the atom and the card draw (current readings, 6 past +
/// 384 forecast hours, 92 past + 16 forecast days) plus a best-effort air-quality call. A good cache younger than 10 minutes IS the answer
/// (a restart must not spend the free daily quota), and only a real reading is ever cached or shown (a quota-error reply is valid JSON too).
final class WeatherService {
    static var lat: Double { AppConfig.shared.location?.lat ?? 0 }      // from config.json; no location = no requests
    static var lon: Double { AppConfig.shared.location?.lon ?? 0 }
    private let store: Store
    private let cache = URL(fileURLWithPath: Demo.cacheDirectory + "/weather-v2.json")
    private var timer: Timer?

    init(store: Store) { self.store = store }

    /// The location changed in config.json: forget the old place's reading and start over (no location: nothing is requested).
    func reconfigure() {
        timer?.invalidate(); timer = nil
        try? FileManager.default.removeItem(at: cache)
        store.set(weather: nil)
        if Needs.isRunning("weather") { start() }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func start() {
        guard AppConfig.shared.location != nil else { return }
        let c = loadCache()
        if let c { store.set(weather: c) }
        if c == nil || Date().timeIntervalSince1970 - c!.syncedAt >= 600 { fetch() }
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in self?.fetch() }
        timer?.tolerance = 60
    }

    private func loadCache() -> WX? { (try? Data(contentsOf: cache)).flatMap { try? JSONDecoder().decode(WX.self, from: $0) } }

    func fetch() {
        let cur = "temperature_2m,apparent_temperature,relative_humidity_2m,is_day,precipitation,weather_code,cloud_cover,pressure_msl,wind_speed_10m,wind_gusts_10m,wind_direction_10m,uv_index,dew_point_2m,visibility"
        let hourly = "temperature_2m,apparent_temperature,weather_code,precipitation_probability,precipitation,relative_humidity_2m,cloud_cover,dew_point_2m,pressure_msl,wind_speed_10m,visibility,uv_index,is_day"
        let daily = "weather_code,temperature_2m_max,temperature_2m_min,apparent_temperature_max,apparent_temperature_min,precipitation_sum,precipitation_hours,precipitation_probability_max,wind_speed_10m_max,wind_gusts_10m_max,wind_direction_10m_dominant,sunrise,sunset,daylight_duration,sunshine_duration,uv_index_max"
        let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(Self.lat)&longitude=\(Self.lon)&current=\(cur)&hourly=\(hourly)&daily=\(daily)&timezone=auto&past_days=92&forecast_days=16&past_hours=6&forecast_hours=384")!
        var req = URLRequest(url: url); req.timeoutInterval = 12
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self else { return }
            guard let data, var w = Self.parse(data) else {
                return      // a failed fetch keeps what is shown (stale is judged from syncedAt)
            }
            self.fetchAirQuality { aq in
                w.aqi = aq; w.syncedAt = Date().timeIntervalSince1970
                try? JSONEncoder().encode(w).write(to: self.cache)
                DispatchQueue.main.async { self.store.set(weather: w) }
            }
        }.resume()
    }

    private func fetchAirQuality(_ done: @escaping (WX.AQ?) -> Void) {
        var req = URLRequest(url: URL(string: "https://air-quality-api.open-meteo.com/v1/air-quality?latitude=\(Self.lat)&longitude=\(Self.lon)&current=us_aqi,pm2_5,pm10")!)
        req.timeoutInterval = 6
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let c = j["current"] as? [String: Any],
                  let a = (c["us_aqi"] as? NSNumber)?.doubleValue else { done(nil); return }
            done(WX.AQ(usAqi: a, pm25: (c["pm2_5"] as? NSNumber)?.doubleValue, pm10: (c["pm10"] as? NSNumber)?.doubleValue))
        }.resume()
    }

    /// Only a real reading comes out (a quota-error reply is valid JSON without `current`).
    static func parse(_ data: Data) -> WX? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let c = j["current"] as? [String: Any],
              let temp = (c["temperature_2m"] as? NSNumber)?.doubleValue else { return nil }
        func d(_ o: [String: Any], _ k: String) -> Double? { (o[k] as? NSNumber)?.doubleValue }
        var w = WX()
        w.cur = WX.Cur(time: c["time"] as? String ?? "", temp: temp, feels: d(c, "apparent_temperature") ?? temp, isDay: Int(d(c, "is_day") ?? 1), code: Int(d(c, "weather_code") ?? 0),
                       humidity: d(c, "relative_humidity_2m"), precip: d(c, "precipitation"), cloud: d(c, "cloud_cover"), pressure: d(c, "pressure_msl"), uv: d(c, "uv_index"),
                       dew: d(c, "dew_point_2m"), visibility: d(c, "visibility"), windSpeed: d(c, "wind_speed_10m"), windGusts: d(c, "wind_gusts_10m"), windDir: d(c, "wind_direction_10m"))
        // Each column is bridged from Foundation to a Swift array ONCE (bridging copies the whole array), then indexed per row.
        func col(_ o: [String: Any], _ k: String) -> [Any] { o[k] as? [Any] ?? [] }
        func num(_ a: [Any], _ i: Int) -> Double? { i < a.count ? (a[i] as? NSNumber)?.doubleValue : nil }
        func str(_ a: [Any], _ i: Int) -> String { i < a.count ? (a[i] as? String ?? "") : "" }
        if let h = j["hourly"] as? [String: Any] {
            let t = col(h, "time"), temp = col(h, "temperature_2m"), code = col(h, "weather_code"), day = col(h, "is_day"), feels = col(h, "apparent_temperature")
            let pop = col(h, "precipitation_probability"), precip = col(h, "precipitation"), hum = col(h, "relative_humidity_2m"), cloud = col(h, "cloud_cover")
            let dew = col(h, "dew_point_2m"), pres = col(h, "pressure_msl"), wind = col(h, "wind_speed_10m"), vis = col(h, "visibility"), uv = col(h, "uv_index")
            w.hours = (0..<t.count).map { i in
                WX.Hour(time: str(t, i), temp: num(temp, i) ?? 0, code: Int(num(code, i) ?? 0), isDay: Int(num(day, i) ?? 1),
                        feels: num(feels, i), pop: num(pop, i), precip: num(precip, i),
                        humidity: num(hum, i), cloud: num(cloud, i), dew: num(dew, i),
                        pressure: num(pres, i), wind: num(wind, i), visibility: num(vis, i), uv: num(uv, i))
            }
        }
        if let dd = j["daily"] as? [String: Any] {
            let t = col(dd, "time"), code = col(dd, "weather_code"), mx = col(dd, "temperature_2m_max"), mn = col(dd, "temperature_2m_min")
            let fMax = col(dd, "apparent_temperature_max"), fMin = col(dd, "apparent_temperature_min"), pop = col(dd, "precipitation_probability_max")
            let pSum = col(dd, "precipitation_sum"), pHours = col(dd, "precipitation_hours"), rise = col(dd, "sunrise"), set = col(dd, "sunset"), uv = col(dd, "uv_index_max")
            let wMax = col(dd, "wind_speed_10m_max"), gMax = col(dd, "wind_gusts_10m_max"), wDir = col(dd, "wind_direction_10m_dominant")
            let light = col(dd, "daylight_duration"), sun = col(dd, "sunshine_duration")
            w.days = (0..<t.count).map { i in
                WX.Day(date: str(t, i), code: Int(num(code, i) ?? 0), max: num(mx, i) ?? 0, min: num(mn, i) ?? 0,
                       feelsMax: num(fMax, i), feelsMin: num(fMin, i), pop: num(pop, i),
                       precipSum: num(pSum, i), precipHours: num(pHours, i),
                       sunrise: String(str(rise, i).suffix(5)), sunset: String(str(set, i).suffix(5)), uv: num(uv, i),
                       windMax: num(wMax, i), gustMax: num(gMax, i), windDir: num(wDir, i),
                       daylight: num(light, i), sunshine: num(sun, i))
            }
        }
        return w
    }

    /// The first version of `parse`, kept only so `--weather-selftest` can prove the fast one gives the same result.
    static func parseReference(_ data: Data) -> WX? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let c = j["current"] as? [String: Any],
              let temp = (c["temperature_2m"] as? NSNumber)?.doubleValue else { return nil }
        func d(_ o: [String: Any], _ k: String) -> Double? { (o[k] as? NSNumber)?.doubleValue }
        var w = WX()
        w.cur = WX.Cur(time: c["time"] as? String ?? "", temp: temp, feels: d(c, "apparent_temperature") ?? temp, isDay: Int(d(c, "is_day") ?? 1), code: Int(d(c, "weather_code") ?? 0),
                       humidity: d(c, "relative_humidity_2m"), precip: d(c, "precipitation"), cloud: d(c, "cloud_cover"), pressure: d(c, "pressure_msl"), uv: d(c, "uv_index"),
                       dew: d(c, "dew_point_2m"), visibility: d(c, "visibility"), windSpeed: d(c, "wind_speed_10m"), windGusts: d(c, "wind_gusts_10m"), windDir: d(c, "wind_direction_10m"))
        func col(_ o: [String: Any], _ k: String) -> [Any] { o[k] as? [Any] ?? [] }
        func num(_ a: [Any], _ i: Int) -> Double? { i < a.count ? (a[i] as? NSNumber)?.doubleValue : nil }
        func str(_ a: [Any], _ i: Int) -> String { i < a.count ? (a[i] as? String ?? "") : "" }
        if let h = j["hourly"] as? [String: Any] {
            let t = col(h, "time")
            w.hours = (0..<t.count).map { i in
                WX.Hour(time: str(t, i), temp: num(col(h, "temperature_2m"), i) ?? 0, code: Int(num(col(h, "weather_code"), i) ?? 0), isDay: Int(num(col(h, "is_day"), i) ?? 1),
                        feels: num(col(h, "apparent_temperature"), i), pop: num(col(h, "precipitation_probability"), i), precip: num(col(h, "precipitation"), i),
                        humidity: num(col(h, "relative_humidity_2m"), i), cloud: num(col(h, "cloud_cover"), i), dew: num(col(h, "dew_point_2m"), i),
                        pressure: num(col(h, "pressure_msl"), i), wind: num(col(h, "wind_speed_10m"), i), visibility: num(col(h, "visibility"), i), uv: num(col(h, "uv_index"), i))
            }
        }
        if let dd = j["daily"] as? [String: Any] {
            let t = col(dd, "time")
            w.days = (0..<t.count).map { i in
                WX.Day(date: str(t, i), code: Int(num(col(dd, "weather_code"), i) ?? 0), max: num(col(dd, "temperature_2m_max"), i) ?? 0, min: num(col(dd, "temperature_2m_min"), i) ?? 0,
                       feelsMax: num(col(dd, "apparent_temperature_max"), i), feelsMin: num(col(dd, "apparent_temperature_min"), i), pop: num(col(dd, "precipitation_probability_max"), i),
                       precipSum: num(col(dd, "precipitation_sum"), i), precipHours: num(col(dd, "precipitation_hours"), i),
                       sunrise: String(str(col(dd, "sunrise"), i).suffix(5)), sunset: String(str(col(dd, "sunset"), i).suffix(5)), uv: num(col(dd, "uv_index_max"), i),
                       windMax: num(col(dd, "wind_speed_10m_max"), i), gustMax: num(col(dd, "wind_gusts_10m_max"), i), windDir: num(col(dd, "wind_direction_10m_dominant"), i),
                       daylight: num(col(dd, "daylight_duration"), i), sunshine: num(col(dd, "sunshine_duration"), i))
            }
        }
        return w
    }
}

/// Condition language, as WeatherHelpers.js.
enum WXText {
    static func label(_ c: Int) -> String {
        switch c {
        case 0: return "Clear"; case 1: return "Mostly Clear"; case 2: return "Partly Cloudy"; case 3: return "Overcast"
        case 45, 48: return "Foggy"; case 51: return "Light Drizzle"; case 53: return "Drizzle"; case 55: return "Heavy Drizzle"
        case 56, 57: return "Freezing Drizzle"; case 61: return "Light Rain"; case 63: return "Rain"; case 65: return "Heavy Rain"
        case 66, 67: return "Freezing Rain"; case 71: return "Light Snow"; case 73: return "Snow"; case 75: return "Heavy Snow"; case 77: return "Snow Grains"
        case 80: return "Light Showers"; case 81: return "Showers"; case 82: return "Violent Showers"; case 85: return "Snow Showers"
        case 86: return "Heavy Snow Showers"; case 95: return "Thunderstorm"; case 96, 99: return "T-storm + Hail"
        default: return "Unknown"
        }
    }
    static func symbol(_ c: Int, day: Bool = true) -> String {
        switch c {
        case 0: return day ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return day ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55, 56, 57: return "cloud.drizzle.fill"
        case 61, 63, 80, 81: return "cloud.rain.fill"
        case 65, 82: return "cloud.heavyrain.fill"
        case 66, 67: return "cloud.sleet.fill"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow.fill"
        case 95, 96, 99: return "cloud.bolt.rain.fill"
        default: return "questionmark.circle"
        }
    }
    static func isWet(_ c: Int) -> Bool { (c >= 51 && c <= 67) || (c >= 80 && c <= 82) || c >= 95 || [71, 73, 75, 77, 85, 86].contains(c) }
    static func windLabel(_ kmh: Double?) -> String {
        guard let k = kmh else { return "" }
        return k < 2 ? "CALM" : k < 12 ? "LIGHT" : k < 20 ? "BREEZY" : k < 30 ? "WINDY" : k < 40 ? "STRONG" : "GALE"
    }
    static func windArrow(_ deg: Double?) -> String {
        guard let d = deg else { return "" }
        return ["↓", "↙", "←", "↖", "↑", "↗", "→", "↘"][Int(((d + 180).truncatingRemainder(dividingBy: 360) / 45).rounded()) % 8]
    }
    static func dew(_ d: Double?) -> String { guard let d else { return "" }; return d < 8 ? "DRY" : d < 13 ? "PLEASANT" : d < 16 ? "HUMID" : d < 20 ? "MUGGY" : "OPPRESSIVE" }
    static func uv(_ u: Double?) -> String { guard let u else { return "—" }; return u < 3 ? "LOW" : u < 6 ? "MODERATE" : u < 8 ? "HIGH" : u < 11 ? "VERY HIGH" : "EXTREME" }
    static func aqi(_ a: Double?) -> String {
        guard let a else { return "—" }
        return a <= 50 ? "GOOD" : a <= 100 ? "MODERATE" : a <= 150 ? "UNHEALTHY · S" : a <= 200 ? "UNHEALTHY" : a <= 300 ? "VERY UNHEALTHY" : "HAZARDOUS"
    }
    /// phase p (0 new, 0.5 full), illumination, name
    static func moon(_ date: Date = Date()) -> (p: Double, illum: Double, name: String) {
        let newMoon = 947182440.0, synodic = 29.530588853 * 86400
        let t = (date.timeIntervalSince1970 - newMoon) / synodic, p = t - t.rounded(.down)
        let name = p < 0.02 || p > 0.98 ? "NEW MOON" : p < 0.23 ? "WAXING CRESCENT" : p < 0.27 ? "FIRST QUARTER" : p < 0.48 ? "WAXING GIBBOUS" : p < 0.52 ? "FULL MOON"
                 : p < 0.73 ? "WANING GIBBOUS" : p < 0.77 ? "LAST QUARTER" : "WANING CRESCENT"
        return (p, (1 - cos(2 * .pi * p)) / 2, name)
    }
    static func mins(_ hhmm: String) -> Int? {
        let p = hhmm.split(separator: ":"); guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]) else { return nil }
        return h * 60 + m
    }
    static func dur(_ m: Int) -> String { m >= 60 ? "\(m / 60)H \(String(format: "%02d", m % 60))M" : "\(m)M" }
}
