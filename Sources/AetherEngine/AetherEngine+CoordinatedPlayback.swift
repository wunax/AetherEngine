import AVFoundation
import CoreMedia
import Foundation

extension AetherEngine {
    /// Identifies the currently loaded item to AVFoundation and supplies a snapshot of its
    /// display-axis timing. Calling this with a new identifier keeps the same coordinator alive
    /// across backend and layer replacements.
    public func transitionToCoordinatedPlaybackItem(
        identifier: String?,
        initialTime: Double = 0,
        initialRate: Float = 0
    ) {
        coordinatedPlaybackActive = identifier != nil
        coordinatedPlaybackItemIdentifier = identifier
        coordinatedPlaybackIntendedRate = initialRate
        isWaitingForCoordinatedPlayback = identifier != nil && initialRate == 0

        var timebase: CMTimebase?
        let status = CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &timebase
        )
        if status == noErr, let timebase {
            CMTimebaseSetTime(timebase, time: CMTime(seconds: max(0, initialTime), preferredTimescale: 600))
            CMTimebaseSetRate(timebase, rate: Double(initialRate))
            playbackCoordinator.transitionToItem(
                withIdentifier: identifier,
                proposingInitialTimingBasedOn: timebase
            )
        } else {
            playbackCoordinator.transitionToItem(
                withIdentifier: identifier,
                proposingInitialTimingBasedOn: nil
            )
        }
    }

    public func endCoordinatedPlayback() {
        coordinatedPlaybackStallSuspension?.end()
        coordinatedPlaybackStallSuspension = nil
        coordinatedPlaybackInterruptionSuspension?.end()
        coordinatedPlaybackInterruptionSuspension = nil
        coordinatedPlaybackActive = false
        coordinatedPlaybackItemIdentifier = nil
        coordinatedPlaybackIntendedRate = 0
        isWaitingForCoordinatedPlayback = false
        playbackCoordinator.transitionToItem(
            withIdentifier: nil,
            proposingInitialTimingBasedOn: nil
        )
    }

    func coordinatedPlaybackCommandApplies(to identifier: String) -> Bool {
        coordinatedPlaybackActive && coordinatedPlaybackItemIdentifier == identifier
    }

    func applyCoordinatedPause(expectedIdentifier: String, waiting: Bool) {
        guard coordinatedPlaybackCommandApplies(to: expectedIdentifier) else { return }
        coordinatedPlaybackIntendedRate = 0
        isWaitingForCoordinatedPlayback = waiting
        pause()
    }

    func applyCoordinatedSeek(expectedIdentifier: String, itemTime: CMTime) async {
        guard coordinatedPlaybackCommandApplies(to: expectedIdentifier) else { return }
        let seconds = itemTime.seconds
        guard seconds.isFinite else { return }
        pause()
        await seek(to: seconds)
        // Non-native hosts historically finalize a seek as playing. A coordinator seek must
        // remain paused until its subsequent play command arrives.
        pause()
    }

    func applyCoordinatedPlay(
        expectedIdentifier: String,
        rate: Float,
        itemTime: CMTime,
        hostTime: CMTime
    ) async {
        guard coordinatedPlaybackCommandApplies(to: expectedIdentifier) else { return }
        let displaySeconds = itemTime.seconds
        guard displaySeconds.isFinite else { return }

        pause()
        await seek(to: displaySeconds)
        pause()
        guard coordinatedPlaybackCommandApplies(to: expectedIdentifier) else { return }

        let clockSeconds = PresentationAxis.source(
            displayTime: displaySeconds,
            origin: sourcePresentationOrigin
        ) - playlistShiftSeconds
        let backendTime = CMTime(seconds: max(0, clockSeconds), preferredTimescale: 600)

        if audioAVPlayerActive, let host = audioAVPlayerHost {
            await host.playCoordinated(rate: rate, atHostTime: hostTime)
        } else if let host = audioHost {
            host.playCoordinated(rate: rate, itemTime: backendTime, hostTime: hostTime)
        } else if let host = softwareHost {
            host.playCoordinated(rate: rate, itemTime: backendTime, hostTime: hostTime)
        } else if let host = nativeHost {
            await host.playCoordinated(rate: rate, atHostTime: hostTime)
        }

        coordinatedPlaybackIntendedRate = rate
        isWaitingForCoordinatedPlayback = false
        state = .playing
    }

    func waitUntilReadyForCoordinatedPlayback(dueDate: Date?) async {
        isWaitingForCoordinatedPlayback = true
        while !isSessionReady {
            guard coordinatedPlaybackActive else { return }
            if let dueDate, Date() >= dueDate { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func updateCoordinatedPlaybackStall(_ buffering: Bool) {
        guard coordinatedPlaybackActive else { return }
        if buffering {
            guard coordinatedPlaybackStallSuspension == nil else { return }
            coordinatedPlaybackStallSuspension = playbackCoordinator.beginSuspension(for: .stallRecovery)
        } else if let suspension = coordinatedPlaybackStallSuspension {
            coordinatedPlaybackStallSuspension = nil
            suspension.end()
            playbackCoordinator.reapplyCurrentItemStateToPlaybackControlDelegate()
        }
    }

    func beginCoordinatedPlaybackInterruption() {
        guard coordinatedPlaybackActive, coordinatedPlaybackInterruptionSuspension == nil else { return }
        coordinatedPlaybackInterruptionSuspension = playbackCoordinator.beginSuspension(for: .audioSessionInterrupted)
    }

    func endCoordinatedPlaybackInterruption() {
        coordinatedPlaybackInterruptionSuspension?.end()
        coordinatedPlaybackInterruptionSuspension = nil
    }
}

final class AetherEnginePlaybackCoordinationDelegate: NSObject,
    AVPlaybackCoordinatorPlaybackControlDelegate,
    @unchecked Sendable
{
    weak var engine: AetherEngine?

    init(engine: AetherEngine) {
        self.engine = engine
    }

    func playbackCoordinator(
        _: AVDelegatingPlaybackCoordinator,
        didIssue playCommand: AVDelegatingPlaybackCoordinatorPlayCommand,
        completionHandler: @escaping @Sendable () -> Void
    ) {
        Task { @MainActor [weak self] in
            defer { completionHandler() }
            await self?.engine?.applyCoordinatedPlay(
                expectedIdentifier: playCommand.expectedCurrentItemIdentifier,
                rate: playCommand.rate,
                itemTime: playCommand.itemTime,
                hostTime: playCommand.hostClockTime
            )
        }
    }

    func playbackCoordinator(
        _: AVDelegatingPlaybackCoordinator,
        didIssue pauseCommand: AVDelegatingPlaybackCoordinatorPauseCommand,
        completionHandler: @escaping @Sendable () -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let engine = self?.engine else {
                completionHandler()
                return
            }
            engine.applyCoordinatedPause(
                expectedIdentifier: pauseCommand.expectedCurrentItemIdentifier,
                waiting: pauseCommand.shouldBufferInAnticipationOfPlayback
            )
            if pauseCommand.shouldBufferInAnticipationOfPlayback {
                await engine.waitUntilReadyForCoordinatedPlayback(dueDate: nil)
            }
            completionHandler()
        }
    }

    func playbackCoordinator(
        _: AVDelegatingPlaybackCoordinator,
        didIssue seekCommand: AVDelegatingPlaybackCoordinatorSeekCommand,
        completionHandler: @escaping @Sendable () -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let engine = self?.engine else {
                completionHandler()
                return
            }
            await engine.applyCoordinatedSeek(
                expectedIdentifier: seekCommand.expectedCurrentItemIdentifier,
                itemTime: seekCommand.itemTime
            )
            if seekCommand.shouldBufferInAnticipationOfPlayback {
                await engine.waitUntilReadyForCoordinatedPlayback(dueDate: seekCommand.completionDueDate)
            }
            completionHandler()
        }
    }

    func playbackCoordinator(
        _: AVDelegatingPlaybackCoordinator,
        didIssue bufferingCommand: AVDelegatingPlaybackCoordinatorBufferingCommand,
        completionHandler: @escaping @Sendable () -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let engine = self?.engine,
                  engine.coordinatedPlaybackCommandApplies(
                      to: bufferingCommand.expectedCurrentItemIdentifier
                  )
            else {
                completionHandler()
                return
            }
            await engine.waitUntilReadyForCoordinatedPlayback(
                dueDate: bufferingCommand.completionDueDate
            )
            completionHandler()
        }
    }
}
