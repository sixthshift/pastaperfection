import Testing
import Foundation
@testable import PastaPerfectionCore

@Suite struct TelemetryTests {
    /// Fresh temp directory per test, cleaned up by the caller via `defer`.
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pastaperfection-telemetry-tests-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - bucket(_:)

    @Test func bucketSamplesSpanningTwoWindowsProducesExactlyTwoBucketsWithNumericAggregates() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // Align base to a 900 s boundary so the math below is easy to reason
        // about: bucket A covers [base, base+900), bucket B covers
        // [base+900, base+1800).
        let bucketStart = Date(timeIntervalSince1970: (base.timeIntervalSince1970 / 900).rounded(.down) * 900)

        // Bucket A: 15 samples, 5 of them paused, 3 of them charging.
        var samplesA: [TelemetrySample] = []
        for i in 0..<15 {
            samplesA.append(TelemetrySample(
                ts: bucketStart.addingTimeInterval(Double(i) * 10),
                percent: 70 + i, // 70...84
                isCharging: i < 3,
                temperatureC: 30.0 + Double(i),
                amperageMA: 100 * i,
                voltageMV: 12_000,
                chargingPaused: i < 5
            ))
        }

        // Bucket B: 5 samples, all in the next 900 s window.
        var samplesB: [TelemetrySample] = []
        for i in 0..<5 {
            samplesB.append(TelemetrySample(
                ts: bucketStart.addingTimeInterval(900 + Double(i) * 10),
                percent: 90,
                isCharging: false,
                temperatureC: 35.0,
                amperageMA: -500,
                voltageMV: 12_100,
                chargingPaused: false
            ))
        }

        let buckets = bucket((samplesA + samplesB).shuffled())
        #expect(buckets.count == 2)

        let a = buckets[0]
        #expect(a.ts == bucketStart)
        #expect(a.count == 15)
        #expect(a.percentMin == 70)
        #expect(a.percentMax == 84)
        // percentAvg = mean(70...84) = 77.0
        #expect(abs(a.percentAvg - 77.0) < 0.001)
        // temperatureCAvg = mean(30...44) = 37.0
        #expect(abs(a.temperatureCAvg - 37.0) < 0.001)
        // pausedFraction: 5 of 15 paused == 1/3.
        #expect(abs(a.pausedFraction - 1.0 / 3.0) < 0.001)
        // chargingFraction: 3 of 15 charging.
        #expect(abs(a.chargingFraction - 0.2) < 0.001)

        let b = buckets[1]
        #expect(b.ts == bucketStart.addingTimeInterval(900))
        #expect(b.count == 5)
        #expect(b.percentMin == 90)
        #expect(b.percentMax == 90)
        #expect(abs(b.percentAvg - 90.0) < 0.001)
        #expect(abs(b.pausedFraction - 0.0) < 0.001)
        #expect(abs(b.chargingFraction - 0.0) < 0.001)
    }

    @Test func bucketEmptyInputYieldsEmptyOutput() {
        #expect(bucket([]).isEmpty)
    }

    // MARK: - maxCapacityMAh / maxCapacityMAhAvg (SPEC §10.3, T032)

    /// Contrast (a): a bucket with some `maxCapacityMAh` nil and the
    /// non-nil ones 7500/7600 averages only the non-nil values (7550), not
    /// treating the nils as zero.
    @Test func bucketMaxCapacityAveragesOnlyNonNilValues() {
        let bucketStart = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = [
            TelemetrySample(
                ts: bucketStart, percent: 70, isCharging: true, temperatureC: 30.0,
                amperageMA: 100, voltageMV: 12_000, chargingPaused: false,
                maxCapacityMAh: 7500
            ),
            TelemetrySample(
                ts: bucketStart.addingTimeInterval(10), percent: 71, isCharging: true, temperatureC: 30.0,
                amperageMA: 100, voltageMV: 12_000, chargingPaused: false,
                maxCapacityMAh: nil
            ),
            TelemetrySample(
                ts: bucketStart.addingTimeInterval(20), percent: 72, isCharging: true, temperatureC: 30.0,
                amperageMA: 100, voltageMV: 12_000, chargingPaused: false,
                maxCapacityMAh: 7600
            )
        ]

        let buckets = bucket(samples)
        #expect(buckets.count == 1)
        #expect(buckets[0].maxCapacityMAhAvg == 7550)
    }

    /// Contrast (b): a bucket where every sample's `maxCapacityMAh` is nil
    /// yields `maxCapacityMAhAvg == nil`, not `0`.
    @Test func bucketAllNilMaxCapacityYieldsNilAverage() {
        let bucketStart = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = [
            TelemetrySample(
                ts: bucketStart, percent: 70, isCharging: true, temperatureC: 30.0,
                amperageMA: 100, voltageMV: 12_000, chargingPaused: false, maxCapacityMAh: nil
            ),
            TelemetrySample(
                ts: bucketStart.addingTimeInterval(10), percent: 71, isCharging: true, temperatureC: 30.0,
                amperageMA: 100, voltageMV: 12_000, chargingPaused: false, maxCapacityMAh: nil
            )
        ]

        let buckets = bucket(samples)
        #expect(buckets.count == 1)
        #expect(buckets[0].maxCapacityMAhAvg == nil)
    }

    /// Contrast (c-1): an old `TelemetrySample` JSON line recorded before
    /// `maxCapacityMAh` existed (no such key) must still decode, defaulting
    /// the new field to `nil` rather than throwing.
    @Test func telemetrySampleDecodesWithoutMaxCapacityKey() throws {
        let json = """
        {"ts":"2023-11-14T22:13:20Z","percent":60,"isCharging":true,"temperatureC":28.5,\
        "amperageMA":1200,"voltageMV":12500,"chargingPaused":false}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TelemetrySample.self, from: Data(json.utf8))

        #expect(decoded.percent == 60)
        #expect(decoded.maxCapacityMAh == nil)
    }

    /// Contrast (c-2): an old `ArchiveSample` JSON line recorded before
    /// `maxCapacityMAhAvg` existed (no such key) must still decode,
    /// defaulting the new field to `nil` rather than throwing.
    @Test func archiveSampleDecodesWithoutMaxCapacityAvgKey() throws {
        let json = """
        {"ts":"2023-11-14T22:13:20Z","percentAvg":75.0,"percentMin":70,"percentMax":80,\
        "temperatureCAvg":30.0,"amperageMAAvg":-400.0,"voltageMVAvg":12000.0,\
        "chargingFraction":0.2,"pausedFraction":0.3,"count":15}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ArchiveSample.self, from: Data(json.utf8))

        #expect(decoded.count == 15)
        #expect(decoded.maxCapacityMAhAvg == nil)
    }

    // MARK: - rotation hook (archive)

    @Test func rotationArchivesDroppedSamplesCoveringTheirTimeRange() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("telemetry.jsonl")
        let archiveURL = dir.appendingPathComponent("telemetry-archive.jsonl")

        let cap = 10
        let log = TelemetryLog(url: url, capLines: cap, archiveURL: archiveURL)
        // Base aligned to a 900 s boundary. Samples are spaced 1000 s apart
        // (wider than the 900 s bucket width) so each individual rotation
        // event — which only ever drops exactly one old line at a time,
        // since `keep = capLines - 1` and one new line is appended — lands
        // its dropped sample in its own distinct 15-min bucket. This makes
        // the archive's bucket structure directly attributable to specific
        // dropped samples, rather than several rotations silently
        // coalescing into one bucket.
        let base = Date(timeIntervalSince1970: (1_700_000_000.0 / 900).rounded(.down) * 900)

        var samples: [TelemetrySample] = []
        for i in 0..<25 {
            let s = sample(ts: base.addingTimeInterval(Double(i) * 1000), percent: i)
            samples.append(s)
            log.append(s)
        }

        // Hot file never exceeds the cap.
        let hotRaw = try String(contentsOf: url, encoding: .utf8)
        let hotLineCount = hotRaw.split(separator: "\n", omittingEmptySubsequences: true).count
        #expect(hotLineCount <= cap)

        // With cap=10 and 25 appends, the dropped samples are the oldest
        // 25 - 10 = 15 (samples[0...14]), one at a time as each rewrite
        // fires starting from the 11th append.
        let droppedSamples = Array(samples[0..<15])

        let archived = log.readArchive()
        #expect(archived.count == droppedSamples.count)

        // Each dropped sample maps to its own bucket (ts = floor(ts/900)*900,
        // count == 1), and every one of those buckets shows up in the
        // archive — i.e. the dropped time range is fully covered.
        let archivedByTs = Dictionary(uniqueKeysWithValues: archived.map { ($0.ts, $0) })
        for dropped in droppedSamples {
            let expectedBucketTs = Date(
                timeIntervalSince1970: (dropped.ts.timeIntervalSince1970 / 900).rounded(.down) * 900
            )
            let found = archivedByTs[expectedBucketTs]
            #expect(found != nil)
            #expect(found?.count == 1)
        }
    }

    @Test func archiveRingCapDropsOldestWhenExceeded() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("telemetry.jsonl")
        let archiveURL = dir.appendingPathComponent("telemetry-archive.jsonl")

        // Small hot cap so rotations happen often, and a tiny archive cap so
        // the archive ring itself has to drop entries.
        let log = TelemetryLog(url: url, capLines: 5, archiveURL: archiveURL, archiveCapLines: 3)
        // Samples spaced 20 minutes apart so essentially every dropped
        // sample lands in its own distinct 15-min bucket, guaranteeing many
        // more than 3 archive lines get produced over the run.
        let base = Date(timeIntervalSince1970: (1_700_000_000.0 / 900).rounded(.down) * 900)

        for i in 0..<30 {
            log.append(sample(ts: base.addingTimeInterval(Double(i) * 1200), percent: i % 100))
        }

        // Hot cap 5, 30 appends → 25 rotations, each dropping exactly one
        // sample into its own bucket (25 new archive lines produced over
        // the run) → archive ring (cap 3) holds exactly the newest 3.
        let archived = log.readArchive()
        #expect(archived.count == 3)

        // The kept buckets are the newest ones (ring drops oldest first):
        // ts values should be strictly increasing.
        let sortedTs = archived.map(\.ts).sorted()
        for i in 1..<sortedTs.count {
            #expect(sortedTs[i] > sortedTs[i - 1])
        }
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
