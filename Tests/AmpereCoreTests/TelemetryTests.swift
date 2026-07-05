import Testing
import Foundation
@testable import AmpereCore

@Suite struct TelemetryTests {
    /// Fresh temp directory per test, cleaned up by the caller via `defer`.
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ampere-telemetry-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Whole-second "now" so round-tripping through the ISO 8601 (no
    /// fractional seconds) encoder used by `TelemetryLog` never loses
    /// precision that would break equality checks below.
    private func wholeSecondNow() -> Date {
        Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())
    }

    private func sample(ts: Date, percent: Int = 50) -> TelemetrySample {
        TelemetrySample(
            ts: ts,
            percent: percent,
            isCharging: true,
            temperatureC: 28.5,
            amperageMA: 1200,
            voltageMV: 12_000,
            chargingPaused: false
        )
    }

    @Test func defaultCapLinesIsTwentyThousand() {
        #expect(TelemetryLog.defaultCapLines == 20_000)
    }

    @Test func ringCapKeepsExactlyCapLinesAndDropsOldest() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("telemetry.jsonl")

        let cap = 50
        let log = TelemetryLog(url: url, capLines: cap)
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        var samples: [TelemetrySample] = []
        for i in 1...(cap + 5) {
            let s = sample(ts: base.addingTimeInterval(Double(i)), percent: i % 100)
            samples.append(s)
            log.append(s)
        }

        // File itself has exactly `cap` lines.
        let raw = try String(contentsOf: url, encoding: .utf8)
        let rawLines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(rawLines.count == cap)

        // Contrast with pre-cap state: before capping, the oldest line would
        // have been sample #1. After capping at `cap` with `cap + 5` total
        // appends, the oldest 5 are gone and the first surviving line is
        // sample #6 (index 5).
        let read = log.read(hoursBack: 1_000_000)
        #expect(read.count == cap)
        #expect(read.first?.ts == samples[5].ts)
        #expect(read.last?.ts == samples[cap + 4].ts)
    }

    @Test func readHoursBackReturnsOnlySamplesNewerThanCutoff() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("telemetry.jsonl")

        let log = TelemetryLog(url: url)
        let now = wholeSecondNow()
        let oldSample = sample(ts: now.addingTimeInterval(-3600 * 5)) // 5h old
        let newSample = sample(ts: now.addingTimeInterval(-60)) // 1 min old

        log.append(oldSample)
        log.append(newSample)

        let recent = log.read(hoursBack: 1)
        #expect(recent.count == 1)
        #expect(recent.first?.ts == newSample.ts)

        // Contrast: asking for a wider window returns both.
        let wider = log.read(hoursBack: 6)
        #expect(wider.count == 2)
    }

    @Test func readSkipsCorruptedLineWithoutCrashing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("telemetry.jsonl")

        let log = TelemetryLog(url: url)
        let now = wholeSecondNow()
        let first = sample(ts: now.addingTimeInterval(-10), percent: 40)
        let second = sample(ts: now.addingTimeInterval(-5), percent: 45)

        log.append(first)

        // Insert a corrupt line directly, bypassing the log's own writer.
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data("{not valid json at all\n".utf8))
        try handle.close()

        log.append(second)

        let read = log.read(hoursBack: 1)
        #expect(read.count == 2)
        #expect(read.map(\.percent) == [40, 45])
    }
}
