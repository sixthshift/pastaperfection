/// Pure, derived-logic core for the top-energy-consumers ranking (SPEC
/// §10.5): joins two snapshots of per-process cumulative metrics by pid and
/// produces a sorted, capped list of deltas. No IOKit, no libproc, no
/// process spawning — everything here is arithmetic over injected values so
/// it's fully unit-testable.

/// A single process's cumulative metric at a point in time (SPEC §10.5).
public struct ProcessSnapshot: Equatable, Sendable {
    public let pid: Int32
    public let name: String
    public let metric: UInt64

    public init(pid: Int32, name: String, metric: UInt64) {
        self.pid = pid
        self.name = name
        self.metric = metric
    }
}

/// A ranked entry: a process and how much its metric grew between two
/// snapshots (SPEC §10.5).
public struct EnergyEntry: Equatable, Sendable {
    public let pid: Int32
    public let name: String
    public let delta: UInt64

    public init(pid: Int32, name: String, delta: UInt64) {
        self.pid = pid
        self.name = name
        self.delta = delta
    }
}

/// Pure computation of the top-energy-consumers ranking (SPEC §10.5).
public enum EnergyRanking {
    /// Joins `previous` and `current` snapshots by `pid` and returns the
    /// top `limit` movers by delta.
    ///
    /// Rules (LOCKED):
    /// - A pid present in only one of the two snapshots is dropped.
    /// - If `current.metric < previous.metric` (counter reset / pid reuse)
    ///   the pid is dropped — never underflows `UInt64`.
    /// - Entries with `delta == 0` are dropped.
    /// - Sorted by `delta` descending, tie-broken by `name` ascending.
    /// - `current`'s `name` is used for the resulting entry.
    /// - Returns at most `limit` entries; `limit <= 0` yields `[]`.
    public static func topConsumers(
        previous: [ProcessSnapshot],
        current: [ProcessSnapshot],
        limit: Int
    ) -> [EnergyEntry] {
        guard limit > 0 else { return [] }

        var previousByPid: [Int32: ProcessSnapshot] = [:]
        for snapshot in previous {
            previousByPid[snapshot.pid] = snapshot
        }

        var entries: [EnergyEntry] = []
        entries.reserveCapacity(current.count)

        for snapshot in current {
            guard let prior = previousByPid[snapshot.pid] else { continue }
            guard snapshot.metric >= prior.metric else { continue }
            let delta = snapshot.metric - prior.metric
            guard delta != 0 else { continue }
            entries.append(EnergyEntry(pid: snapshot.pid, name: snapshot.name, delta: delta))
        }

        entries.sort { lhs, rhs in
            if lhs.delta != rhs.delta {
                return lhs.delta > rhs.delta
            }
            return lhs.name < rhs.name
        }

        return Array(entries.prefix(limit))
    }
}
