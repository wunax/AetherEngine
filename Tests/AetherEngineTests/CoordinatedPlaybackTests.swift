import AVFoundation
@testable import AetherEngine
import XCTest

@MainActor
final class CoordinatedPlaybackTests: XCTestCase {
    func testAVPlayerStartUsesHostClockSchedulingForNumericTimes() {
        let itemTime = CMTime(seconds: 42, preferredTimescale: 600)
        let hostTime = CMTime(seconds: 100, preferredTimescale: 1_000_000_000)

        XCTAssertEqual(
            CoordinatedAVPlayerStartStrategy.resolve(itemTime: itemTime, hostTime: hostTime),
            .scheduled
        )
    }

    func testAVPlayerStartFallsBackToImmediatePlaybackForInvalidTimes() {
        let numericTime = CMTime(seconds: 42, preferredTimescale: 600)

        XCTAssertEqual(
            CoordinatedAVPlayerStartStrategy.resolve(itemTime: .invalid, hostTime: numericTime),
            .immediate
        )
        XCTAssertEqual(
            CoordinatedAVPlayerStartStrategy.resolve(itemTime: numericTime, hostTime: .invalid),
            .immediate
        )
        XCTAssertEqual(
            CoordinatedAVPlayerStartStrategy.resolve(itemTime: .indefinite, hostTime: numericTime),
            .immediate
        )
    }

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

    func testCommandInducedBufferingDoesNotStartAStall() {
        var gate = CoordinatedPlaybackStallGate()

        let commandActions = gate.beginTransportCommand()
        XCTAssertTrue(commandActions.contains { action in
            if case .scheduleSuppressionTimeout = action { return true }
            return false
        })
        XCTAssertEqual(gate.updateBuffering(true), [])
        XCTAssertEqual(gate.updateBuffering(false), [])

        XCTAssertEqual(gate.transportDidSettle(), [.cancelSuppressionTimeout])
        XCTAssertFalse(gate.hasActiveSuspension)
    }

    func testShortBufferingTransitionOnlyCancelsDebounce() {
        var gate = CoordinatedPlaybackStallGate()

        let actions = gate.updateBuffering(true)
        guard case let .scheduleDebounce(generation) = actions.first else {
            return XCTFail("Expected a debounce to be scheduled")
        }

        XCTAssertEqual(gate.updateBuffering(false), [.cancelDebounce])
        XCTAssertEqual(gate.debounceDidFire(generation: generation), [])
        XCTAssertFalse(gate.hasActiveSuspension)
    }

    func testSustainedBufferingCreatesOneSuspensionAndReappliesOnce() {
        var gate = CoordinatedPlaybackStallGate()

        let actions = gate.updateBuffering(true)
        guard case let .scheduleDebounce(generation) = actions.first else {
            return XCTFail("Expected a debounce to be scheduled")
        }

        XCTAssertEqual(gate.debounceDidFire(generation: generation), [.beginSuspension])
        XCTAssertEqual(gate.debounceDidFire(generation: generation), [])
        XCTAssertTrue(gate.hasActiveSuspension)
        XCTAssertEqual(gate.updateBuffering(true), [])
        XCTAssertEqual(gate.updateBuffering(false), [.endSuspension(reapply: true)])
        XCTAssertEqual(gate.updateBuffering(false), [])
        XCTAssertFalse(gate.hasActiveSuspension)
    }

    func testReappliedCommandSuppressesItsTransientBuffering() {
        var gate = CoordinatedPlaybackStallGate()
        let initialActions = gate.updateBuffering(true)
        guard case let .scheduleDebounce(generation) = initialActions.first else {
            return XCTFail("Expected a debounce to be scheduled")
        }
        _ = gate.debounceDidFire(generation: generation)
        _ = gate.updateBuffering(false)

        _ = gate.beginTransportCommand()
        XCTAssertEqual(gate.updateBuffering(true), [])
        XCTAssertEqual(gate.updateBuffering(false), [])
        XCTAssertEqual(gate.transportDidSettle(), [.cancelSuppressionTimeout])
        XCTAssertFalse(gate.hasActiveSuspension)
    }

    func testItemTransitionAndEndResetCancelPendingWorkAndClearSuppression() {
        var debounceGate = CoordinatedPlaybackStallGate()
        _ = debounceGate.updateBuffering(true)
        XCTAssertEqual(debounceGate.reset(), [.cancelDebounce])

        var suppressionGate = CoordinatedPlaybackStallGate()
        _ = suppressionGate.beginTransportCommand()
        XCTAssertEqual(suppressionGate.reset(), [.cancelSuppressionTimeout])
        XCTAssertFalse(suppressionGate.isSuppressingStalls)

        var activeGate = CoordinatedPlaybackStallGate()
        let actions = activeGate.updateBuffering(true)
        guard case let .scheduleDebounce(generation) = actions.first else {
            return XCTFail("Expected a debounce to be scheduled")
        }
        _ = activeGate.debounceDidFire(generation: generation)

        XCTAssertEqual(activeGate.reset(), [.endSuspension(reapply: false)])
        XCTAssertFalse(activeGate.hasActiveSuspension)
    }

    func testSuppressionTimeoutAllowsARealSustainedStall() {
        var gate = CoordinatedPlaybackStallGate()
        let commandActions = gate.beginTransportCommand()
        guard case let .scheduleSuppressionTimeout(generation) = commandActions.last else {
            return XCTFail("Expected a suppression timeout to be scheduled")
        }

        XCTAssertEqual(gate.updateBuffering(true), [])
        let timeoutActions = gate.suppressionTimeoutDidFire(generation: generation)
        guard case let .scheduleDebounce(debounceGeneration) = timeoutActions.first else {
            return XCTFail("Expected buffering to be debounced after the safety timeout")
        }

        XCTAssertEqual(
            gate.debounceDidFire(generation: debounceGeneration),
            [.beginSuspension]
        )
    }
}
