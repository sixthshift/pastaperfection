import Testing
@testable import PastaPerfectionCore

@Suite struct ScaffoldTests {
    @Test func versionStringIsNotEmpty() {
        #expect(!Version.string.isEmpty)
    }
}
