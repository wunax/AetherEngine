import AVFoundation
import CoreMedia
import Foundation

enum CoordinatedAVPlayerStartStrategy: Equatable {
    case scheduled
    case immediate

    static func resolve(itemTime: CMTime, hostTime: CMTime) -> Self {
        itemTime.isNumeric && hostTime.isNumeric ? .scheduled : .immediate
    }
}

@MainActor
func startAVPlayerCoordinated(
    _ player: AVPlayer,
    rate: Float,
    atHostTime hostTime: CMTime
) {
    let itemTime = player.currentTime()
    switch CoordinatedAVPlayerStartStrategy.resolve(itemTime: itemTime, hostTime: hostTime) {
    case .scheduled:
        player.setRate(rate, time: itemTime, atHostTime: hostTime)
    case .immediate:
        player.playImmediately(atRate: rate)
    }
}

struct CoordinatedPlaybackStallGate {
    enum Action: Equatable {
        case cancelDebounce
        case cancelSuppressionTimeout
        case scheduleDebounce(Int)
        case scheduleSuppressionTimeout(Int)
        case beginSuspension
        case endSuspension(reapply: Bool)
    }

    private(set) var isSuppressingStalls = false
    private(set) var hasActiveSuspension = false
    private(set) var pendingDebounceGeneration: Int?
    private(set) var suppressionGeneration: Int?
    private var isBuffering = false
    private var nextGeneration = 0

    mutating func beginTransportCommand() -> [Action] {
        var actions = cancelPendingActions()
        nextGeneration += 1
        isSuppressingStalls = true
        suppressionGeneration = nextGeneration
        actions.append(.scheduleSuppressionTimeout(nextGeneration))
        return actions
    }

    mutating func transportDidSettle() -> [Action] {
        guard isSuppressingStalls else { return [] }
        isSuppressingStalls = false
        suppressionGeneration = nil
        var actions: [Action] = [.cancelSuppressionTimeout]
        actions.append(contentsOf: scheduleDebounceIfNeeded())
        return actions
    }

    mutating func updateBuffering(_ buffering: Bool) -> [Action] {
        isBuffering = buffering
        if !buffering {
            var actions = cancelDebounce()
            if hasActiveSuspension {
                hasActiveSuspension = false
                actions.append(.endSuspension(reapply: true))
            }
            return actions
        }
        return scheduleDebounceIfNeeded()
    }

    mutating func debounceDidFire(generation: Int) -> [Action] {
        guard pendingDebounceGeneration == generation else { return [] }
        pendingDebounceGeneration = nil
        guard isBuffering, !isSuppressingStalls, !hasActiveSuspension else { return [] }
        hasActiveSuspension = true
        return [.beginSuspension]
    }

    mutating func suppressionTimeoutDidFire(generation: Int) -> [Action] {
        guard suppressionGeneration == generation else { return [] }
        suppressionGeneration = nil
        isSuppressingStalls = false
        return scheduleDebounceIfNeeded()
    }

    mutating func reset() -> [Action] {
        var actions = cancelPendingActions()
        if hasActiveSuspension {
            hasActiveSuspension = false
            actions.append(.endSuspension(reapply: false))
        }
        isBuffering = false
        isSuppressingStalls = false
        return actions
    }

    private mutating func scheduleDebounceIfNeeded() -> [Action] {
        guard isBuffering,
              !isSuppressingStalls,
              !hasActiveSuspension,
              pendingDebounceGeneration == nil
        else { return [] }
        nextGeneration += 1
        pendingDebounceGeneration = nextGeneration
        return [.scheduleDebounce(nextGeneration)]
    }

    private mutating func cancelPendingActions() -> [Action] {
        cancelDebounce() + cancelSuppressionTimeout()
    }

    private mutating func cancelDebounce() -> [Action] {
        guard pendingDebounceGeneration != nil else { return [] }
        pendingDebounceGeneration = nil
        return [.cancelDebounce]
    }

    private mutating func cancelSuppressionTimeout() -> [Action] {
        guard suppressionGeneration != nil else { return [] }
        suppressionGeneration = nil
        return [.cancelSuppressionTimeout]
    }
}

extension AetherEngine {
    /// Identifies the currently loaded item to AVFoundation and supplies a snapshot of its
    /// display-axis timing. Calling this with a new identifier keeps the same coordinator alive
    /// across backend and layer replacements.
    public func transitionToCoordinatedPlaybackItem(
        identifier: String?,
        initialTime: Double = 0,
        initialRate: Float = 0
    ) {
        resetCoordinatedPlaybackStallTracking()
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
        resetCoordinatedPlaybackStallTracking()
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
        resetCoordinatedPlaybackStallTracking()
        coordinatedPlaybackIntendedRate = 0
        isWaitingForCoordinatedPlayback = waiting
        pause()
    }

    func applyCoordinatedSeek(expectedIdentifier: String, itemTime: CMTime) async {
        guard coordinatedPlaybackCommandApplies(to: expectedIdentifier) else { return }
        let seconds = itemTime.seconds
        guard seconds.isFinite else { return }
        beginCoordinatedTransportCommand()
        pause()
        await seek(to: seconds)
        // Non-native hosts historically finalize a seek as playing. A coordinator seek must
        // remain paused until its subsequent play command arrives.
        pause()
        if softwareHost != nil || audioHost != nil || (nativeHost == nil && !audioAVPlayerActive) {
            coordinatedTransportDidSettle()
        }
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

        beginCoordinatedTransportCommand()
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
            host.playCoordinated(rate: rate, atHostTime: hostTime)
        } else if let host = audioHost {
            host.playCoordinated(rate: rate, itemTime: backendTime, hostTime: hostTime)
            coordinatedTransportDidSettle()
        } else if let host = softwareHost {
            host.playCoordinated(rate: rate, itemTime: backendTime, hostTime: hostTime)
            coordinatedTransportDidSettle()
        } else if let host = nativeHost {
            host.playCoordinated(rate: rate, atHostTime: hostTime)
        } else {
            coordinatedTransportDidSettle()
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
        performCoordinatedPlaybackStallActions(
            coordinatedPlaybackStallGate.updateBuffering(buffering)
        )
    }

    func coordinatedTransportDidSettle() {
        performCoordinatedPlaybackStallActions(
            coordinatedPlaybackStallGate.transportDidSettle()
        )
    }

    private func beginCoordinatedTransportCommand() {
        performCoordinatedPlaybackStallActions(
            coordinatedPlaybackStallGate.beginTransportCommand()
        )
    }

    private func resetCoordinatedPlaybackStallTracking() {
        performCoordinatedPlaybackStallActions(coordinatedPlaybackStallGate.reset())
    }

    private func performCoordinatedPlaybackStallActions(
        _ actions: [CoordinatedPlaybackStallGate.Action]
    ) {
        for action in actions {
            switch action {
            case .cancelDebounce:
                coordinatedPlaybackStallDebounceTask?.cancel()
                coordinatedPlaybackStallDebounceTask = nil
            case .cancelSuppressionTimeout:
                coordinatedPlaybackSuppressionTimeoutTask?.cancel()
                coordinatedPlaybackSuppressionTimeoutTask = nil
            case let .scheduleDebounce(generation):
                coordinatedPlaybackStallDebounceTask?.cancel()
                coordinatedPlaybackStallDebounceTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard !Task.isCancelled, let self else { return }
                    self.performCoordinatedPlaybackStallActions(
                        self.coordinatedPlaybackStallGate.debounceDidFire(generation: generation)
                    )
                }
            case let .scheduleSuppressionTimeout(generation):
                coordinatedPlaybackSuppressionTimeoutTask?.cancel()
                coordinatedPlaybackSuppressionTimeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled, let self else { return }
                    self.performCoordinatedPlaybackStallActions(
                        self.coordinatedPlaybackStallGate.suppressionTimeoutDidFire(
                            generation: generation
                        )
                    )
                }
            case .beginSuspension:
                guard coordinatedPlaybackStallSuspension == nil else { continue }
                coordinatedPlaybackStallSuspension = playbackCoordinator.beginSuspension(
                    for: .stallRecovery
                )
            case let .endSuspension(reapply):
                guard let suspension = coordinatedPlaybackStallSuspension else { continue }
                coordinatedPlaybackStallSuspension = nil
                suspension.end()
                if reapply {
                    playbackCoordinator.reapplyCurrentItemStateToPlaybackControlDelegate()
                }
            }
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
