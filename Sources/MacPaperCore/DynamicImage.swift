import Foundation
import ImageIO

/// Which picture of a dynamic HEIC to show, read from the metadata macOS's own dynamic
/// wallpapers carry. Three formats exist:
///
/// - `solar`: each picture is tied to a sun position (altitude and azimuth).
/// - `h24`: each picture is tied to a time of day.
/// - `apr`: one picture for Light mode and one for Dark mode.
public struct DynamicSchedule: Equatable {
    public enum Mode: Equatable {
        case solar([SolarFrame])
        case timeOfDay([TimedFrame])
        case appearance(light: Int, dark: Int)
    }

    public struct SolarFrame: Equatable {
        public let index: Int
        /// Degrees above the horizon.
        public let altitude: Double
        /// Degrees clockwise from north. Below 180 the sun is rising.
        public let azimuth: Double
    }

    public struct TimedFrame: Equatable {
        public let index: Int
        /// Fraction of the day, 0 at midnight.
        public let time: Double
    }

    public let mode: Mode
    public let frameCount: Int
    /// The picture to use as a preview.
    public let previewIndex: Int

    public var summary: String {
        switch mode {
        case .solar: "Follows the sun"
        case .timeOfDay: "Changes through the day"
        case .appearance: "Follows Light and Dark mode"
        }
    }

    public var followsAppearance: Bool {
        if case .appearance = mode { return true }
        return false
    }

    // MARK: - Reading

    private static let namespace = "http://ns.apple.com/namespace/1.0/"

    public static func read(from url: URL) -> DynamicSchedule? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        return read(from: source)
    }

    public static func read(from source: CGImageSource) -> DynamicSchedule? {
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return nil }
        for index in Set([CGImageSourceGetPrimaryImageIndex(source), 0]) {
            guard let metadata = CGImageSourceCopyMetadataAtIndex(source, index, nil),
                  let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] else { continue }
            for tag in tags {
                guard (CGImageMetadataTagCopyNamespace(tag) as String?) == namespace,
                      let name = CGImageMetadataTagCopyName(tag) as String?,
                      let encoded = CGImageMetadataTagCopyValue(tag) as? String,
                      let data = Data(base64Encoded: encoded),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let schedule = parse(name: name, plist: plist, count: count) else { continue }
                return schedule
            }
        }
        return nil
    }

    private static func parse(name: String, plist: [String: Any], count: Int) -> DynamicSchedule? {
        let appearance = plist["ap"] as? [String: Any]
        let light = int(appearance?["l"])
        let valid = { (index: Int) in index >= 0 && index < count }

        switch name {
        case "solar":
            let frames = (plist["si"] as? [[String: Any]] ?? []).compactMap { entry -> SolarFrame? in
                guard let index = int(entry["i"]), valid(index),
                      let altitude = double(entry["a"]), let azimuth = double(entry["z"]) else { return nil }
                return SolarFrame(index: index, altitude: altitude, azimuth: azimuth)
            }
            guard !frames.isEmpty else { return nil }
            let brightest = frames.max { $0.altitude < $1.altitude }!.index
            return DynamicSchedule(mode: .solar(frames), frameCount: count, previewIndex: light ?? brightest)
        case "h24":
            let frames = (plist["ti"] as? [[String: Any]] ?? []).compactMap { entry -> TimedFrame? in
                guard let index = int(entry["i"]), valid(index), let time = double(entry["t"]) else { return nil }
                return TimedFrame(index: index, time: time)
            }.sorted { $0.time < $1.time }
            guard !frames.isEmpty else { return nil }
            // A day picture and a night picture placed at fixed hours is a day-and-night
            // wallpaper, and the hours are often wrong (Dome puts night at noon). Following the
            // sun gets it right everywhere: day from sunrise, night from sunset.
            if frames.count == 2, let light, let dark = int(appearance?["d"]), light != dark,
               Set(frames.map(\.index)) == [light, dark] {
                return DynamicSchedule(mode: .solar([
                    SolarFrame(index: light, altitude: -3, azimuth: 90),
                    SolarFrame(index: dark, altitude: -3, azimuth: 270),
                ]), frameCount: count, previewIndex: light)
            }
            let noon = frames.last { $0.time <= 0.5 } ?? frames[0]
            return DynamicSchedule(mode: .timeOfDay(frames), frameCount: count, previewIndex: light ?? noon.index)
        case "apr":
            guard let lightIndex = int(plist["l"]), let darkIndex = int(plist["d"]),
                  valid(lightIndex), valid(darkIndex) else { return nil }
            return DynamicSchedule(mode: .appearance(light: lightIndex, dark: darkIndex),
                                   frameCount: count, previewIndex: lightIndex)
        default:
            return nil
        }
    }

    // Property lists from different tools store these numbers as numbers or as strings.
    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        double(value).map { Int($0) }
    }

    // MARK: - Choosing a picture

    public func frameIndex(at date: Date = Date(), dark: Bool,
                           location: Coordinates = .current) -> Int {
        switch mode {
        case .appearance(let light, let darkIndex):
            return dark ? darkIndex : light
        case .timeOfDay(let frames):
            let calendar = Calendar.current
            let seconds = date.timeIntervalSince(calendar.startOfDay(for: date))
            let now = seconds / 86_400
            return (frames.last { $0.time <= now } ?? frames.last!).index
        case .solar(let frames):
            return Self.solarIndex(frames, at: date, location: location)
        }
    }

    /// Turns each sun position into the moment it happens today, morning positions before
    /// noon and evening ones after, and shows the last one that has passed. A position the sun
    /// never reaches today, as in a northern winter, falls back to noon or midnight.
    private static func solarIndex(_ frames: [SolarFrame], at date: Date, location: Coordinates) -> Int {
        let (noon, timed) = solarTimes(frames, near: date, location: location)
        let now = date.timeIntervalSince(noon) / 60
        return (timed.last { $0.minutes <= now } ?? timed.last!).index
    }

    /// Each frame's moment, in minutes from the solar noon nearest `date`, in order.
    private static func solarTimes(_ frames: [SolarFrame], near date: Date,
                                   location: Coordinates) -> (noon: Date, [(minutes: Double, index: Int)]) {
        let noon = Sun.solarNoon(near: date, longitude: location.longitude)
        let samples = stride(from: -720.0, through: 720.0, by: 5.0).map { minutes in
            (minutes, Sun.altitude(at: noon.addingTimeInterval(minutes * 60), location: location))
        }
        let morning = samples.filter { $0.0 <= 0 }
        let evening = samples.filter { $0.0 >= 0 }

        // Some files only describe sunrise, or only sunset. The other half of the day then runs
        // the same pictures in reverse.
        var frames = frames
        let rising = frames.filter { $0.azimuth < 180 }
        if rising.isEmpty || rising.count == frames.count {
            frames += frames.map { SolarFrame(index: $0.index, altitude: $0.altitude, azimuth: 360 - $0.azimuth) }
        }

        let timed = frames.enumerated().map { order, frame -> (minutes: Double, order: Int, index: Int) in
            let minutes: Double
            if frame.azimuth < 180 {
                minutes = morning.first { $0.1 >= frame.altitude }?.0 ?? 0
            } else {
                minutes = evening.first { $0.1 <= frame.altitude }?.0 ?? 720
            }
            return (minutes, order, frame.index)
        }.sorted { ($0.minutes, $0.order) < ($1.minutes, $1.order) }
        return (noon, timed.map { ($0.minutes, $0.index) })
    }

    /// When each picture takes over during the calendar day containing `date`, oldest first, with
    /// the picture already showing at midnight first. Nil for Light and Dark, which has no times.
    public func timeline(on date: Date = Date(), location: Coordinates = .current) -> [(start: Date, index: Int)]? {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)

        var changes: [(start: Date, index: Int)]
        switch mode {
        case .appearance:
            return nil
        case .timeOfDay(let frames):
            changes = frames.map { (start.addingTimeInterval($0.time * 86_400), $0.index) }
        case .solar(let frames):
            let (noon, timed) = Self.solarTimes(frames, near: start.addingTimeInterval(12 * 3600), location: location)
            changes = timed.map { (noon.addingTimeInterval($0.minutes * 60), $0.index) }
        }

        var result = [(start: start, index: frameIndex(at: start, dark: false, location: location))]
        for change in changes.sorted(by: { $0.start < $1.start })
        where change.start > start && change.start < end && change.index != result.last?.index {
            result.append(change)
        }
        return result
    }
}

public struct Coordinates: Equatable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Where the sun is judged from, without asking for Location access: the reference city of
    /// the Mac's time zone, from the system's time zone table. Close enough for picking which
    /// picture of a dynamic wallpaper to show.
    public static var current: Coordinates {
        let zone = TimeZone.current
        if let cached = cache, cached.zone == zone.identifier { return cached.coordinates }
        let coordinates = lookUp(zone.identifier) ?? estimate(zone)
        cache = (zone.identifier, coordinates)
        return coordinates
    }

    private static var cache: (zone: String, coordinates: Coordinates)?

    private static func estimate(_ zone: TimeZone) -> Coordinates {
        let standardOffset = Double(zone.secondsFromGMT()) - zone.daylightSavingTimeOffset()
        return Coordinates(latitude: 40, longitude: standardOffset / 240)
    }

    private static func lookUp(_ identifier: String) -> Coordinates? {
        guard let table = try? String(contentsOfFile: "/usr/share/zoneinfo/zone.tab", encoding: .utf8) else {
            return nil
        }
        for line in table.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t")
            guard fields.count >= 3, fields[2] == identifier else { continue }
            return parse(String(fields[1]))
        }
        return nil
    }

    /// ISO 6709 as used by zone.tab: `+DDMM+DDDMM` or `+DDMMSS+DDDMMSS`.
    private static func parse(_ value: String) -> Coordinates? {
        guard let split = value.dropFirst().firstIndex(where: { $0 == "+" || $0 == "-" }) else { return nil }
        let latitude = degrees(String(value[..<split]), degreeDigits: 2)
        let longitude = degrees(String(value[split...]), degreeDigits: 3)
        guard let latitude, let longitude else { return nil }
        return Coordinates(latitude: latitude, longitude: longitude)
    }

    private static func degrees(_ value: String, degreeDigits: Int) -> Double? {
        guard let sign = value.first, sign == "+" || sign == "-" else { return nil }
        let digits = Array(value.dropFirst())
        guard digits.count >= degreeDigits + 2, digits.allSatisfy(\.isNumber) else { return nil }
        let number = { (range: Range<Int>) in Double(String(digits[range])) ?? 0 }
        var result = number(0..<degreeDigits) + number(degreeDigits..<degreeDigits + 2) / 60
        if digits.count >= degreeDigits + 4 { result += number(degreeDigits + 2..<degreeDigits + 4) / 3600 }
        return sign == "-" ? -result : result
    }
}

/// NOAA's low-precision solar position, good to about a degree.
enum Sun {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private struct Terms {
        let equationOfTime: Double  // minutes
        let declination: Double     // radians
    }

    private static func terms(at date: Date) -> (Terms, minutesIntoDay: Double) {
        let day = Double(utc.ordinality(of: .day, in: .year, for: date) ?? 1)
        let start = utc.startOfDay(for: date)
        let minutes = date.timeIntervalSince(start) / 60
        let g = 2 * Double.pi / 365 * (day - 1 + (minutes / 60 - 12) / 24)
        let equation = 229.18 * (0.000075 + 0.001868 * cos(g) - 0.032077 * sin(g)
            - 0.014615 * cos(2 * g) - 0.040849 * sin(2 * g))
        let declination = 0.006918 - 0.399912 * cos(g) + 0.070257 * sin(g)
            - 0.006758 * cos(2 * g) + 0.000907 * sin(2 * g)
            - 0.002697 * cos(3 * g) + 0.00148 * sin(3 * g)
        return (Terms(equationOfTime: equation, declination: declination), minutes)
    }

    static func altitude(at date: Date, location: Coordinates) -> Double {
        let (terms, minutes) = terms(at: date)
        let solarMinutes = minutes + terms.equationOfTime + 4 * location.longitude
        let hourAngle = (solarMinutes / 4 - 180) * .pi / 180
        let latitude = location.latitude * .pi / 180
        let cosine = sin(latitude) * sin(terms.declination)
            + cos(latitude) * cos(terms.declination) * cos(hourAngle)
        return 90 - acos(min(max(cosine, -1), 1)) * 180 / .pi
    }

    /// The solar noon of the solar day that `date` falls in, so `date` is within about twelve
    /// hours of it.
    static func solarNoon(near date: Date, longitude: Double) -> Date {
        let shift = longitude * 240
        let meanSolar = date.addingTimeInterval(shift)
        let meanNoon = utc.startOfDay(for: meanSolar).addingTimeInterval(12 * 3600 - shift)
        let (terms, _) = terms(at: meanNoon)
        return meanNoon.addingTimeInterval(-terms.equationOfTime * 60)
    }
}
