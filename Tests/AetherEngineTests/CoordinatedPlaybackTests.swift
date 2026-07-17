import AVFoundation
@testable import AetherEngine
import XCTest

@MainActor
final class CoordinatedPlaybackTests: XCTestCase {
    func testCoordinatorIsRetainedAcrossItemTransitions() throws {
        let engine = try AetherEngine()
        let coordinator = engine.playbackCoordinator

        engine.transitionToCoordinatedPlaybackItem(
            identifier: "episode-1",
            initialTime: 42,
        )
        engine.transitionToCoordinatedPlaybackItem(
            identifier: "episode-2",
            initialTime: 0,
        )

        XCTAssertTrue(coordinator === engine.playbackCoordinator)
        XCTAssertTrue(engine.coordinatedPlaybackCommandApplies(to: "episode-2"))
        XCTAssertFalse(engine.coordinatedPlaybackCommandApplies(to: "episode-1"))
    }

    func testMismatchedCommandsCannotChangeIntendedRate() throws {
        let engine = try AetherEngine()
        engine.transitionToCoordinatedPlaybackItem(
            identifier: "expected",
            initialTime: 0,
            initialRate: 1,
        )

        engine.applyCoordinatedPause(expectedIdentifier: "other", waiting: false)

        XCTAssertEqual(engine.coordinatedPlaybackIntendedRate, 1)
    }

    func testEndingCoordinationClearsPublishedState() throws {
        let engine = try AetherEngine()
        engine.transitionToCoordinatedPlaybackItem(
            identifier: "episode",
            initialTime: 15,
            initialRate: 1,
        )

        engine.endCoordinatedPlayback()

        XCTAssertFalse(engine.coordinatedPlaybackCommandApplies(to: "episode"))
        XCTAssertEqual(engine.coordinatedPlaybackIntendedRate, 0)
        XCTAssertFalse(engine.isWaitingForCoordinatedPlayback)
    }

    func testPresentationAxisRoundTripsCoordinatorItemTime() {
        let sourceTime = 109.5
        let origin = 100.25
        let displayTime = PresentationAxis.display(sourcePTS: sourceTime, origin: origin)

        XCTAssertEqual(
            PresentationAxis.source(displayTime: displayTime, origin: origin),
            sourceTime,
            accuracy: 0.000_001,
        )
    }
}
