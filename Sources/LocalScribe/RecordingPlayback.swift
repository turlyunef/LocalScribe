import AVFoundation
import Combine
import LocalScribeCore

/// One local player for the open recording card. Playback activity is observed
/// by the controls and transcript directly, independently of the archive model.
@MainActor final class RecordingPlayback: ObservableObject {
    struct Source: Equatable, Sendable {
        let folder: URL
        let relativePath: String
        let durationMs: Int
        let channels: Int
        let tools: URL

        init(_ manifest: Manifest, folder: URL, tools: URL) {
            self.folder = folder
            relativePath = manifest.originalRelativePath
            durationMs = manifest.durationMs
            channels = manifest.channels
            self.tools = tools
        }
    }

    enum State: Equatable {
        case idle, loading, ready, failed(String)
    }

    private static let maximumSeekError = 0.05

    @Published private(set) var state = State.idle
    @Published private(set) var position: Double?
    @Published private(set) var duration = 0.0
    @Published private(set) var isPlaying = false
    @Published var speed: Float = 1 {
        didSet { if isPlaying, seekID == nil, state == .ready { player?.rate = speed } }
    }
    @Published var skipSeconds = 10
    @Published var followsTranscript = true
    @Published var skipsPauses = false {
        didSet { skipCurrentPause() }
    }

    private var pauseIndex = PlaybackPauseIndex()
    private(set) var transcriptTask: Task<Void, Never>?

    private var source: Source?
    private var player: AVPlayer?
    private var openedAudio: OpenedAudio?
    private var statusObserver: NSKeyValueObservation?
    private var notificationObservers: [NSObjectProtocol] = []
    private var timeObserver: Any?
    private var seekID: UUID?
    private var lastCompletedSeekTarget: Double?
    private var openID: UUID?
    private var fileTasks: [UUID: Task<Void, Never>] = [:]
    private var visibleCards: Set<UUID> = []

    isolated deinit {
        transcriptTask?.cancel()
        if let openID { fileTasks[openID]?.cancel() }
        releasePlayer()
    }

    func cardAppeared(_ id: UUID, source: Source?, transcript: Transcript? = nil) {
        visibleCards.insert(id)
        select(source)
        updateTranscript(transcript)
    }

    func cardDisappeared(_ id: UUID) {
        visibleCards.remove(id)
        if visibleCards.isEmpty { select(nil) }
    }

    func select(_ next: Source?) {
        guard source != next else { return }
        if let openID { fileTasks[openID]?.cancel() }
        openID = nil
        releasePlayer()
        source = next
        updateTranscript(nil)
        isPlaying = false
        position = nil
        duration = max(0, Double(next?.durationMs ?? 0) / 1000)
        state = .idle
    }

    func updateTranscript(_ transcript: Transcript?) {
        transcriptTask?.cancel()
        transcriptTask = nil
        pauseIndex = PlaybackPauseIndex()
        guard source != nil, let transcript else { return }
        transcriptTask = Task { [weak self] in
            let index = await Task.detached(priority: .userInitiated) {
                PlaybackPauseIndex(transcript.segments)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.pauseIndex = index
            self.transcriptTask = nil
            self.skipCurrentPause()
        }
    }

    func toggle() {
        guard source != nil else { return }
        if isPlaying {
            isPlaying = false
            player?.pause()
        } else {
            seek(to: position == duration ? 0 : position ?? 0, play: true)
        }
    }

    func skip(_ direction: Int) {
        seek(to: (position ?? 0) + Double(direction * skipSeconds))
    }

    func moveToSegment(_ direction: Int) {
        guard let target = pauseIndex.adjacentSpeech(at: position ?? 0, direction: direction),
              target < duration else { return }
        seek(to: target)
    }

    func seek(to seconds: Double, play: Bool = false) {
        guard source != nil, seconds.isFinite else { return }
        var target = min(max(0, seconds), duration)
        if play || isPlaying, skipsPauses, let next = pauseIndex.nextSpeech(at: target), next < duration {
            target = next
        }
        position = target
        isPlaying = (play || isPlaying) && (duration == 0 || target < duration)
        switch state {
        case .idle, .failed: open()
        case .loading: break
        case .ready: seekPlayer()
        }
    }

    func shutdown() async {
        select(nil)
        for task in Array(fileTasks.values) { await task.value }
    }

    private func open(forceCopy: Bool = false) {
        guard let source else { return }
        let request = UUID()
        openID = request
        state = .loading
        fileTasks[request] = Task { [weak self] in
            defer { self?.fileTasks.removeValue(forKey: request) }
            do {
                let audio = try await Self.openAudio(source, forceCopy: forceCopy)
                guard let self, self.openID == request, !Task.isCancelled else {
                    await Self.removeTemporaryAudio(audio.directory)
                    return
                }
                self.attach(audio)
            } catch {
                guard let self, self.openID == request, !Task.isCancelled else { return }
                self.fail(error)
            }
        }
    }

    private func attach(_ audio: OpenedAudio) {
        openedAudio = audio
        duration = audio.duration
        if let position, position >= duration {
            self.position = duration
            isPlaying = false
        }
        let item = AVPlayerItem(asset: audio.asset)
        let player = AVPlayer(playerItem: item)
        self.player = player
        statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.player?.currentItem === item else { return }
                switch item.status {
                case .readyToPlay:
                    guard self.state != .ready else { return }
                    self.state = .ready
                    self.seekPlayer()
                case .failed: self.recover()
                default: break
                }
            }
        }
        let center = NotificationCenter.default
        notificationObservers = [
            center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.player?.currentItem === item, self.seekID == nil,
                          player.currentTime().seconds >= self.duration - 0.05 else { return }
                    self.isPlaying = false
                    self.position = self.duration
                }
            },
            center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.player?.currentItem === item else { return }
                    self.recover()
                }
            }
        ]
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self, weak player] _ in
            MainActor.assumeIsolated {
                guard let self, let player, self.player === player, self.seekID == nil, self.state == .ready else { return }
                let time = player.currentTime().seconds
                guard time.isFinite else { return }
                let position = min(max(0, time), self.duration)
                if self.position != position { self.position = position }
                self.skipCurrentPause()
            }
        }
    }

    private func seekPlayer() {
        guard let player, let item = player.currentItem else { return }
        let request = UUID()
        seekID = request
        lastCompletedSeekTarget = nil
        player.pause()
        item.cancelPendingSeeks()
        let seconds = position ?? 0
        let target = CMTime(seconds: seconds, preferredTimescale: 1_000_000)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.seekID == request else { return }
                self.seekID = nil
                let time = player.currentTime().seconds
                guard finished, time.isFinite, abs(time - seconds) < Self.maximumSeekError else {
                    self.recover()
                    return
                }
                self.lastCompletedSeekTarget = seconds
                if !self.skipCurrentPause(), self.isPlaying { player.rate = self.speed }
            }
        }
    }

    @discardableResult
    private func skipCurrentPause() -> Bool {
        guard skipsPauses, isPlaying, state == .ready, seekID == nil,
              let position, let next = pauseIndex.nextSpeech(at: position), next < duration else { return false }
        // A successful precise seek may leave the clock just before its target.
        // Let playback cross that boundary instead of seeking there every tick.
        if next == lastCompletedSeekTarget, next - position < Self.maximumSeekError {
            return false
        }
        seek(to: next)
        return true
    }

    private func recover() {
        let usedOriginal = openedAudio?.directory == nil
        releasePlayer()
        if usedOriginal {
            open(forceCopy: true)
        } else {
            fail(ScribeError.message("Не удалось воспроизвести аудио."))
        }
    }

    private func fail(_ error: Error) {
        releasePlayer()
        openID = nil
        isPlaying = false
        let message = (error as? ScribeError)?.localizedDescription ?? "Не удалось воспроизвести аудио."
        state = .failed(L10n.message(L10n.text(message)))
    }

    private func releasePlayer() {
        seekID = nil
        lastCompletedSeekTarget = nil
        statusObserver?.invalidate()
        statusObserver = nil
        notificationObservers.forEach(NotificationCenter.default.removeObserver)
        notificationObservers.removeAll()
        if let player {
            if let timeObserver { player.removeTimeObserver(timeObserver) }
            player.pause()
            player.currentItem?.cancelPendingSeeks()
            player.replaceCurrentItem(with: nil)
        }
        timeObserver = nil
        player = nil
        if let directory = openedAudio?.directory {
            let cleanup = UUID()
            fileTasks[cleanup] = Task { [weak self] in
                await Self.removeTemporaryAudio(directory)
                self?.fileTasks.removeValue(forKey: cleanup)
            }
        }
        openedAudio = nil
    }

    private struct OpenedAudio {
        let asset: AVURLAsset
        let duration: Double
        let directory: URL?
    }

    private static func openAudio(_ source: Source, forceCopy: Bool) async throws -> OpenedAudio {
        let fileTask = Task.detached(priority: .userInitiated) { try source.prepare(forceCopy: forceCopy) }
        let (url, directory) = try await withTaskCancellationHandler {
            try await fileTask.value
        } onCancel: {
            fileTask.cancel()
        }
        do {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: url, options: [
                AVURLAssetPreferPreciseDurationAndTimingKey: true,
                AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue
            ])
            let (playable, duration) = try await asset.load(.isPlayable, .duration)
            try Task.checkCancellation()
            let seconds = duration.seconds
            guard playable, seconds.isFinite, seconds > 0,
                  seconds < Double(Manifest.maximumDurationMs) / 1000 + 1 else {
                throw ScribeError.message("Не удалось воспроизвести аудио.")
            }
            return OpenedAudio(asset: asset, duration: seconds, directory: directory)
        } catch {
            await removeTemporaryAudio(directory)
            try Task.checkCancellation()
            if directory == nil { return try await openAudio(source, forceCopy: true) }
            throw error
        }
    }

    private static func removeTemporaryAudio(_ directory: URL?) async {
        guard let directory else { return }
        await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: directory) }.value
    }
}

private extension RecordingPlayback.Source {
    func prepare(forceCopy: Bool) throws -> (URL, URL?) {
        try Task.checkCancellation()
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        let sourceFolder = folder.appendingPathComponent("source", isDirectory: true)
        let original = folder.appendingPathComponent(relativePath)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard components.count == 2, components[0] == "source", components[1].hasPrefix("original."),
              [folder, sourceFolder].allSatisfy({ url in
                  guard let values = try? url.resourceValues(forKeys: keys) else { return false }
                  return values.isDirectory == true && values.isSymbolicLink == false
              }),
              let values = try? original.resourceValues(forKeys: keys),
              values.isRegularFile == true, values.isSymbolicLink == false else {
            throw ScribeError.message("Исходный аудиофайл недоступен.")
        }
        // Raw AAC seeks can drift. Ogg streams need a seekable PCM container
        // on systems where the native player cannot open them.
        guard forceCopy || ["aac", "adts", "ogg", "oga", "opus"].contains(original.pathExtension.lowercased()) else {
            return (original, nil)
        }

        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("LocalScribe-playback-\(UUID().uuidString)", isDirectory: true)
        let copy = directory.appendingPathComponent("audio.caf")
        let outputChannels = min(2, max(1, channels))
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var prepared = false
        defer { if !prepared { try? fm.removeItem(at: directory) } }
        try Disk.requireSpace(Int64(max(0, min(durationMs, Manifest.maximumDurationMs))) * Int64(96 * outputChannels) + 1_000_000, at: directory)
        _ = try Media.execute(tools.appendingPathComponent("ffmpeg"), [
            "-nostdin", "-n", "-v", "error", "-xerror", "-protocol_whitelist", "file,pipe",
            "-i", original.path, "-map", "0:a:0", "-vn",
            "-t", String(Manifest.maximumDurationMs / 1000 + 1),
            "-ac", String(outputChannels), "-ar", "48000", "-c:a", "pcm_s16le", copy.path
        ], cancellable: true)
        try Task.checkCancellation()
        prepared = true
        return (copy, directory)
    }
}
