import Darwin
import AmpereCore

/// Thin, NOT-unit-tested libproc shim (SPEC §10.5) feeding the pure, fully
/// unit-tested `EnergyRanking.topConsumers` in `AmpereCore`. Runs only in
/// the `Ampere` app process (never the daemon — no root needed), driven by
/// `StatsView`'s third visible-gated 10 s timer. Defensive throughout: any
/// per-pid read that fails is skipped rather than propagated — this must
/// never crash the dashboard.
enum EnergySampler {
    /// Metric selection (LOCKED — SPEC §10.5), kept to this single spot:
    /// `ri_billed_energy` (nanojoules, populated on Apple Silicon) is the
    /// primary metric. **Fallback rule** (documented, not wired, per the
    /// ticket): if this hardware's `ri_billed_energy` deltas come back
    /// all-zero, switch this to `info.ri_user_time + info.ri_system_time`
    /// and record the switch in `docs/energy-findings.md` — that
    /// determination happens at the HW gate, not at build time.
    private static func metric(from info: rusage_info_v4) -> UInt64 {
        info.ri_billed_energy
    }

    /// Retained snapshot from the previous `sample(limit:)` call. `nil`
    /// before the first call (there's nothing to diff against yet).
    private static var previousSnapshot: [ProcessSnapshot]?

    /// Enumerates every live pid via `proc_listallpids`, then reads a name
    /// (`proc_name`) and cumulative energy (`proc_pid_rusage`) for each.
    /// Any pid that errors on either call is skipped — never crashes.
    static func snapshot() -> [ProcessSnapshot] {
        let initialCount = proc_listallpids(nil, 0)
        guard initialCount > 0 else { return [] }

        // Pad the buffer above the sizing call's count: pids can appear
        // between that call and the fetch call below (process churn).
        var pids = [pid_t](repeating: 0, count: Int(initialCount) + 64)
        let bufferSize = Int32(pids.count * MemoryLayout<pid_t>.size)
        let filledBytes = pids.withUnsafeMutableBufferPointer { buffer -> Int32 in
            proc_listallpids(buffer.baseAddress, bufferSize)
        }
        guard filledBytes > 0 else { return [] }
        let filledCount = min(pids.count, Int(filledBytes) / MemoryLayout<pid_t>.size)

        var snapshots: [ProcessSnapshot] = []
        snapshots.reserveCapacity(filledCount)

        for index in 0..<filledCount {
            let pid = pids[index]
            guard pid > 0 else { continue }

            var nameBuffer = [CChar](repeating: 0, count: 256)
            let nameLength = nameBuffer.withUnsafeMutableBufferPointer { buffer -> Int32 in
                proc_name(pid, buffer.baseAddress, UInt32(buffer.count))
            }
            guard nameLength > 0 else { continue }
            let name = String(cString: nameBuffer)
            guard !name.isEmpty else { continue }

            var info = rusage_info_v4()
            let rc = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { reboundPtr in
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, reboundPtr)
                }
            }
            guard rc == 0 else { continue }

            snapshots.append(ProcessSnapshot(pid: pid, name: name, metric: metric(from: info)))
        }

        return snapshots
    }

    /// Snapshots the current process table, diffs it against the previously
    /// retained snapshot via `EnergyRanking.topConsumers`, then retains the
    /// new snapshot for next time. Returns `[]` on the first-ever call
    /// (nothing to diff against yet).
    static func sample(limit: Int) -> [EnergyEntry] {
        let current = snapshot()
        defer { previousSnapshot = current }
        guard let previous = previousSnapshot else { return [] }
        return EnergyRanking.topConsumers(previous: previous, current: current, limit: limit)
    }
}
