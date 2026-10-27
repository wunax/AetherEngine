import Testing
@testable import AetherEngine

@Suite("Presented source time")
struct PresentedSourceTimeTests {

    @Test("loopback adds the seam shift unless the display axis is the item axis")
    func loopbackFold() {
        #expect(AetherEngine.loopbackSourceSeconds(renderedItemSeconds: 12.5, shift: 3600,
                                                   displayAxisIsItemAxis: false) == 3612.5)
        #expect(AetherEngine.loopbackSourceSeconds(renderedItemSeconds: 12.5, shift: 3600,
                                                   displayAxisIsItemAxis: true) == 12.5)
    }

    @Test("remote HLS subtracts the measured item lead and never goes negative")
    func remoteHLSFold() {
        #expect(AetherEngine.remoteHLSSourceSeconds(renderedItemSeconds: 10, itemOffset: 0.4) == 9.6)
        #expect(AetherEngine.remoteHLSSourceSeconds(renderedItemSeconds: 0.2, itemOffset: 0.4) == 0)
    }

    @Test("no session has no presented time")
    @MainActor
    func nilWithoutSession() throws {
        #expect(try AetherEngine().presentedSourceTime == nil)
    }
}
