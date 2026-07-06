import Foundation

/// Telemetry sampler — SPEC §3, §5 Phase 3.
///
/// One JSON object per line, one sample per 60 s, ring-capped at 20,000
/// lines (rewrite the file when exceeded, keeping the newest samples). This
/// file owns the on-disk format and ring-cap bookkeeping only; the daemon
/// (Phase 3 wiring) decides when to call `append(_:)` and how to answer
/// `get-stats` via `read(hoursBack:)`.

/// One telemetry sample, as persisted to `telemetry.jsonl` (SPEC §3).
/// Field shape mirrors `BatteryReading` (SPEC §4 key list) plus
/// `chargingPaused`, since stats/heat-protection UI (Phase 3) needs to know
/// whether the daemon was inhibiting charging at sample time, not just the
/// raw battery numbers.
public struct TelemetrySample: Codable, Equatable, Sendable {
    public var ts: Date
    public var percent: Int
    public var isCharging: Bool
    public var temperatureC: Double
    /// Signed milliamps; negative while discharging.
    public var amperageMA: Int
    public var voltageMV: Int
    /// Whether the daemon was actively inhibiting charging (limit or heat)
    /// at the moment this sample was taken.
    public var chargingPaused: Bool

    public init(
        ts: Date,
        percent: Int,
        isCharging: Bool,
        temperatureC: Double,
        amperageMA: Int,
        voltageMV: Int,
        chargingPaused: Bool
    ) {
        self.ts = ts
        self.percent = percent
        self.isCharging = isCharging
        self.temperatureC = temperatureC
        self.amperageMA = amperageMA
        self.voltageMV = voltageMV
        self.chargingPaused = chargingPaused
    }
}

/// One 15-minute downsampled bucket, as persisted to
/// `telemetry-archive.jsonl` (SPEC §9.2). Produced by `bucket(_:)` from the
/// `TelemetrySample`s a hot-ring rotation drops, so ~13 months of coarse
/// history survives past the 20,000-line hot ring's ~14-day window.
public struct ArchiveSample: Codable, Equatable, Sendable {
    /// Bucket start, 15-minute aligned (`floor(ts / 900 s) * 900 s`).
    public var ts: Date
    public var percentAvg: Double
    public var percentMin: Int
    public var percentMax: Int
    public var temperatureCAvg: Double
    public var amperageMAAvg: Double
    public var voltageMVAvg: Double
    /// Fraction (0...1) of the bucket's samples with `isCharging == true`.
    public var chargingFraction: Double
    /// Fraction (0...1) of the bucket's samples with `chargingPaused == true`.
    public var pausedFraction: Double
    /// Number of raw samples folded into this bucket.
    public var count: Int

    public init(
        ts: Date,
        percentAvg: Double,
        percentMin: Int,
        percentMax: Int,
        temperatureCAvg: Double,
        amperageMAAvg: Double,
        voltageMVAvg: Double,
        chargingFraction: Double,
        pausedFraction: Double,
        count: Int
    ) {
        self.ts = ts
        self.percentAvg = percentAvg
        self.percentMin = percentMin
        self.percentMax = percentMax
        self.temperatureCAvg = temperatureCAvg
        self.amperageMAAvg = amperageMAAvg
        self.voltageMVAvg = voltageMVAvg
        self.chargingFraction = chargingFraction
        self.pausedFraction = pausedFraction
        self.count = count
    }
}

/// 15-minute bucket width, in seconds (SPEC §9.2: "bucket key =
/// `floor(ts / 900 s)`").
private let archiveBucketSeconds: TimeInterval = 900

/// Pure downsample step for the telemetry archive (SPEC §9.2): groups
/// `samples` into 15-minute buckets keyed by `floor(ts / 900 s)` and reduces
/// each bucket to one `ArchiveSample` (arithmetic means, min/max percent,
/// charging/paused fractions). Order of `samples` doesn't matter; the
/// result is always sorted by `ts` ascending. Empty input yields `[]`.
public func bucket(_ samples: [TelemetrySample]) -> [ArchiveSample] {
    guard !samples.isEmpty else { return [] }

    var buckets: [Int64: [TelemetrySample]] = [:]
    for sample in samples {
        let key = Int64((sample.ts.timeIntervalSince1970 / archiveBucketSeconds).rounded(.down))
        buckets[key, default: []].append(sample)
    }

    return buckets.keys.sorted().map { key -> ArchiveSample in
        let group = buckets[key]!
        let count = group.count
        let n = Double(count)
        let bucketStart = Date(timeIntervalSince1970: Double(key) * archiveBucketSeconds)

        let percentSum = group.reduce(0.0) { $0 + Double($1.percent) }
        let temperatureSum = group.reduce(0.0) { $0 + $1.temperatureC }
        let amperageSum = group.reduce(0.0) { $0 + Double($1.amperageMA) }
        let voltageSum = group.reduce(0.0) { $0 + Double($1.voltageMV) }
        let chargingCount = group.filter(\.isCharging).count
        let pausedCount = group.filter(\.chargingPaused).count

        return ArchiveSample(
            ts: bucketStart,
            percentAvg: percentSum / n,
            percentMin: group.map(\.percent).min() ?? 0,
            percentMax: group.map(\.percent).max() ?? 0,
            temperatureCAvg: temperatureSum / n,
            amperageMAAvg: amperageSum / n,
            voltageMVAvg: voltageSum / n,
            chargingFraction: Double(chargingCount) / n,
            pausedFraction: Double(pausedCount) / n,
            count: count
        )
    }
}

/// Append-only JSONL telemetry log at `url`, ring-capped at `capLines`
/// (SPEC §3: "ring-capped at 20,000 lines (rewrite file when exceeded)").
///
/// Not thread-safe by itself — callers (the daemon) are expected to only
/// ever call `append(_:)` from a single serialized context, matching how
/// every other piece of daemon state is only touched from the main queue
/// (see `DaemonServer`'s doc comment).
public final class TelemetryLog {
    /// SPEC §3: ring-cap at 20,000 lines.
    public static let defaultCapLines = 20_000
    /// SPEC §9.2: archive ring-cap at 40,000 lines (≈ 416 days of 15-min
    /// buckets).
    public static let defaultArchiveCapLines = 40_000

    private let url: URL
    private let capLines: Int
    private var lineCount: Int?

    private let archiveURL: URL
    private let archiveCapLines: Int

    public init(
        url: URL,
        capLines: Int = TelemetryLog.defaultCapLines,
        archiveURL: URL? = nil,
        archiveCapLines: Int = TelemetryLog.defaultArchiveCapLines
    ) {
        self.url = url
        self.capLines = capLines
        self.archiveURL = archiveURL ?? url.deletingLastPathComponent()
            .appendingPathComponent("telemetry-archive.jsonl")
        self.archiveCapLines = archiveCapLines
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Appends one sample as a single JSON line, creating the file/containing
    /// directory if needed. When appending would push the file over
    /// `capLines`, the file is rewritten first, keeping only the newest
    /// `capLines - 1` existing lines, so the result after this append is
    /// exactly `capLines` lines (the ring never exceeds the cap).
    public func append(_ sample: TelemetrySample) {
        let count = currentLineCount()

        guard let line = try? Self.encoder.encode(sample),
              let lineString = String(data: line, encoding: .utf8) else {
            return
        }

        if count >= capLines {
            // Rewrite, dropping the oldest lines so that after appending the
            // new sample the file holds exactly `capLines` lines.
            let existing = readRawLines()
            let keep = max(capLines - 1, 0)
            let dropped = existing.prefix(max(existing.count - keep, 0))
            let newest = existing.suffix(keep)

            // SPEC §9.2 rotation hook: lines about to be dropped from the
            // hot ring are decoded (corrupt lines tolerated, matching
            // `read`'s tolerance), downsampled into 15-min buckets, and
            // folded into the archive BEFORE the hot rewrite below.
            archiveDroppedLines(dropped)

            let rewritten = (newest + [lineString]).joined(separator: "\n") + "\n"
            try? rewritten.data(using: .utf8)?.write(to: url, options: .atomic)
            lineCount = newest.count + 1
            return
        }

        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(Data((lineString + "\n").utf8))
        }

        lineCount = count + 1
    }

    /// Reads all samples newer than `hoursBack` hours ago. Corrupt lines
    /// (invalid JSON, wrong shape) are skipped rather than causing a crash
    /// or an error — a single bad line must never take down stats.
    ///
    /// NOTE: `hoursBack: 0` here means "nothing newer than now" (an empty
    /// cutoff window) — this is the pre-existing, unchanged contract for
    /// every current call site. It is NOT the same as `get-stats`'s new
    /// `"hours":0` meaning "all history" (SPEC §9.3); callers that want all
    /// hot samples should use `readAll()` instead.
    public func read(hoursBack: Double) -> [TelemetrySample] {
        let cutoff = Date().addingTimeInterval(-hoursBack * 3600)
        return decodedSamples(from: readRawLines()).filter { $0.ts >= cutoff }
    }

    /// Reads every hot-file sample, unfiltered (SPEC §9.3: `get-stats`'s
    /// `"hours":0` means "all history"). Corrupt lines are skipped, same as
    /// `read(hoursBack:)`.
    public func readAll() -> [TelemetrySample] {
        decodedSamples(from: readRawLines())
    }

    private func decodedSamples(from lines: [String]) -> [TelemetrySample] {
        lines.compactMap { line -> TelemetrySample? in
            guard !line.isEmpty,
                  let sample = try? Self.decoder.decode(TelemetrySample.self, from: Data(line.utf8)) else {
                return nil
            }
            return sample
        }
    }

    /// Reads all archived buckets (SPEC §9.2). Corrupt lines are skipped,
    /// matching `read`'s tolerance for the hot file.
    public func readArchive() -> [ArchiveSample] {
        readRawLines(at: archiveURL).compactMap { line -> ArchiveSample? in
            guard !line.isEmpty,
                  let sample = try? Self.decoder.decode(ArchiveSample.self, from: Data(line.utf8)) else {
                return nil
            }
            return sample
        }
    }

    // MARK: - Internals

    /// The current on-disk line count, computed once (by counting lines) and
    /// cached in-memory thereafter, per the ticket's ring-cap bookkeeping.
    private func currentLineCount() -> Int {
        if let lineCount { return lineCount }
        let count = readRawLines().count
        lineCount = count
        return count
    }

    private func readRawLines() -> [String] {
        readRawLines(at: url)
    }

    private func readRawLines(at fileURL: URL) -> [String] {
        guard let data = try? Data(contentsOf: fileURL),
              let contents = String(data: data, encoding: .utf8) else {
            return []
        }
        return contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// Decodes `droppedLines` (hot-ring lines about to be discarded on
    /// rotation), buckets them via `bucket(_:)`, and folds the resulting
    /// archive lines into the archive file, applying the archive's own
    /// rewrite-when-exceeded ring cap (SPEC §9.2). Corrupt lines among
    /// `droppedLines` are silently skipped, matching `read`'s tolerance.
    private func archiveDroppedLines<S: Sequence>(_ droppedLines: S) where S.Element == String {
        let droppedSamples = decodedSamples(from: Array(droppedLines))
        guard !droppedSamples.isEmpty else { return }

        let newBuckets = bucket(droppedSamples)
        let newLines = newBuckets.compactMap { archiveSample -> String? in
            guard let data = try? Self.encoder.encode(archiveSample),
                  let string = String(data: data, encoding: .utf8) else {
                return nil
            }
            return string
        }
        guard !newLines.isEmpty else { return }

        let existing = readRawLines(at: archiveURL)
        let combined = existing + newLines
        let kept = combined.count > archiveCapLines ? Array(combined.suffix(archiveCapLines)) : combined

        let dir = archiveURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rewritten = kept.joined(separator: "\n") + "\n"
        try? rewritten.data(using: .utf8)?.write(to: archiveURL, options: .atomic)
    }
}
