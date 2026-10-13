import Testing
@testable import Eavesdroppy

@Test func packageLoads() {
    #expect(Pipeline.timeout(for: "ask") == 600)
}
