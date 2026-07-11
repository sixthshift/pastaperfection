import Testing
@testable import PastaPerfectionCore

@Suite struct EnergyRankingTests {
    @Test func ordersByDeltaDescending() {
        let previous = [
            ProcessSnapshot(pid: 1, name: "alpha", metric: 100),
            ProcessSnapshot(pid: 2, name: "beta", metric: 100),
        ]
        let current = [
            ProcessSnapshot(pid: 1, name: "alpha", metric: 300),
            ProcessSnapshot(pid: 2, name: "beta", metric: 150),
        ]

        let result = EnergyRanking.topConsumers(previous: previous, current: current, limit: 10)

        #expect(result == [
            EnergyEntry(pid: 1, name: "alpha", delta: 200),
            EnergyEntry(pid: 2, name: "beta", delta: 50),
        ])
    }

    @Test func equalDeltaTieBrokenByNameAscending() {
        let previous = [
            ProcessSnapshot(pid: 1, name: "zeta", metric: 100),
            ProcessSnapshot(pid: 2, name: "alpha", metric: 100),
        ]
        let current = [
            ProcessSnapshot(pid: 1, name: "zeta", metric: 200),
            ProcessSnapshot(pid: 2, name: "alpha", metric: 200),
        ]

        let result = EnergyRanking.topConsumers(previous: previous, current: current, limit: 10)

        #expect(result == [
            EnergyEntry(pid: 2, name: "alpha", delta: 100),
            EnergyEntry(pid: 1, name: "zeta", delta: 100),
        ])
    }

    @Test func topLimitCapsToBiggestMovers() {
        let previous = [
            ProcessSnapshot(pid: 1, name: "small", metric: 0),
            ProcessSnapshot(pid: 2, name: "medium", metric: 0),
            ProcessSnapshot(pid: 3, name: "large", metric: 0),
        ]
        let current = [
            ProcessSnapshot(pid: 1, name: "small", metric: 10),
            ProcessSnapshot(pid: 2, name: "medium", metric: 50),
            ProcessSnapshot(pid: 3, name: "large", metric: 100),
        ]

        let result = EnergyRanking.topConsumers(previous: previous, current: current, limit: 2)

        #expect(result == [
            EnergyEntry(pid: 3, name: "large", delta: 100),
            EnergyEntry(pid: 2, name: "medium", delta: 50),
        ])
    }

    @Test func pidOnlyInCurrentIsDropped() {
        let previous = [ProcessSnapshot(pid: 1, name: "alpha", metric: 100)]
        let current = [
            ProcessSnapshot(pid: 1, name: "alpha", metric: 200),
            ProcessSnapshot(pid: 2, name: "newcomer", metric: 500),
        ]

        let result = EnergyRanking.topConsumers(previous: previous, current: current, limit: 10)

        #expect(result == [EnergyEntry(pid: 1, name: "alpha", delta: 100)])
    }

    @Test func pidOnlyInPreviousIsDropped() {
        let previous = [
            ProcessSnapshot(pid: 1, name: "alpha", metric: 100),
            ProcessSnapshot(pid: 2, name: "gone", metric: 500),
        ]
        let current = [ProcessSnapshot(pid: 1, name: "alpha", metric: 200)]

        let result = EnergyRanking.topConsumers(previous: previous, current: current, limit: 10)

        #expect(result == [EnergyEntry(pid: 1, name: "alpha", delta: 100)])
    }

    @Test func metricResetIsDroppedWithoutUnderflow() {
        let previous = [ProcessSnapshot(pid: 1, name: "alpha", metric: UInt64.max - 10)]
        let current = [ProcessSnapshot(pid: 1, name: "alpha", metric: 5)]

        let result = EnergyRanking.topConsumers(previous: previous, current: current, limit: 10)

        #expect(result == [])
    }

    @Test func zeroDeltaIsDropped() {
        let previous = [ProcessSnapshot(pid: 1, name: "alpha", metric: 100)]
        let current = [ProcessSnapshot(pid: 1, name: "alpha", metric: 100)]

        let result = EnergyRanking.topConsumers(previous: previous, current: current, limit: 10)

        #expect(result == [])
    }

    @Test func emptyInputsProduceEmptyOutput() {
        let result = EnergyRanking.topConsumers(previous: [], current: [], limit: 10)
        #expect(result == [])
    }

    @Test func zeroLimitProducesEmptyOutput() {
        let previous = [ProcessSnapshot(pid: 1, name: "alpha", metric: 100)]
        let current = [ProcessSnapshot(pid: 1, name: "alpha", metric: 200)]

        let result = EnergyRanking.topConsumers(previous: previous, current: current, limit: 0)

        #expect(result == [])
    }
}
