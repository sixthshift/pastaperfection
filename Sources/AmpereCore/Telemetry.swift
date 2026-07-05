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

    private let url: URL
    private let capLines: Int
    private var lineCount: Int?

    public init(url: URL, capLines: Int = TelemetryLog.defaultCapLines) {
        self.url = url
        self.capLines = capLines
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
            let newest = existing.suffix(keep)
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
    public func read(hoursBack: Double) -> [TelemetrySample] {
        let cutoff = Date().addingTimeInterval(-hoursBack * 3600)
        return readRawLines().compactMap { line -> TelemetrySample? in
            guard !line.isEmpty,
                  let sample = try? Self.decoder.decode(TelemetrySample.self, from: Data(line.utf8)) else {
                return nil
            }
            return sample
        }.filter { $0.ts >= cutoff }
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
        guard let data = try? Data(contentsOf: url),
              let contents = String(data: data, encoding: .utf8) else {
            return []
        }
        return contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}
