import Foundation

struct Place: Equatable {
    let name: String
    /// "Region, Country" when the service gives them.
    let region: String
    let lat: Double
    let lon: Double
}

enum GeoOutcome: Equatable {
    case found([Place])
    case noMatch
    case offline(String)
}

enum Geocode {
    static func url(_ query: String) -> String {
        "https://geocoding-api.open-meteo.com/v1/search?name=\(percentEncode(query.trimmingCharacters(in: .whitespaces)))&count=5&language=en&format=json"
    }

    /// Unreserved characters pass; every other byte (spaces, accents) is %-encoded.
    static func percentEncode(_ s: String) -> String {
        var out = ""
        for b in s.utf8 {
            let c = Character(UnicodeScalar(b))
            if (b < 0x80 && (c.isLetter || c.isNumber)) || "-_.~".contains(c) {
                out.append(c)
            } else {
                out += String(format: "%%%02X", b)
            }
        }
        return out
    }

    /// Parses the geocoding response. No `results` means no match; malformed JSON throws.
    static func parse(_ json: Data) throws -> [Place] {
        guard let obj = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw SetupError("the lookup did not return JSON")
        }
        guard let results = obj["results"] as? [[String: Any]] else { return [] }
        var out: [Place] = []
        for r in results {
            guard let name = r["name"] as? String, let lat = r["latitude"] as? Double, let lon = r["longitude"] as? Double else { continue }
            let region = ["admin1", "country"]
                .compactMap { r[$0] as? String }
                .filter { !$0.isEmpty && $0 != name }
                .joined(separator: ", ")
            out.append(Place(name: name, region: region, lat: lat, lon: lon))
        }
        return out
    }

    /// Runs /usr/bin/curl (4 s limit, no shell). Blocking: call it from a background queue.
    static func search(_ query: String) -> GeoOutcome {
        if query.trimmingCharacters(in: .whitespaces).isEmpty { return .noMatch }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = ["-s", "--max-time", "4", url(query)]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return .offline("curl is not available") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return .offline("could not reach open-meteo.com") }
        do {
            let places = try parse(data)
            return places.isEmpty ? .noMatch : .found(places)
        } catch {
            return .offline("the lookup answered with something unexpected")
        }
    }

    /// "53.55, 10.00" typed by hand: two numbers within range.
    static func parseCoordinates(_ text: String) -> (Double, Double)? {
        let parts = text.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        guard parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]) else { return nil }
        guard (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        return (lat, lon)
    }
}
