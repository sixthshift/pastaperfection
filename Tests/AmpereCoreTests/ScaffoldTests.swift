import Testing
@testable import AmpereCore

@Suite struct ScaffoldTests {
    @Test func versionStringIsNotEmpty() {
        #expect(!Version.string.isEmpty)
    }
}
