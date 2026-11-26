import AVFoundation
import OSLog
import SwiftUI

enum LocalPlaybackIdentity: Codable, Hashable {
    case movie(UUID)
    case download(owner: String, id: String)
}

enum LocalPlaybackPreferences {
    static let speedKey = "foldot.playback.localDefaultSpeed"
    static let loopKey = "foldot.playback.loopLocalVideos"
    static let pauseBetweenFoldsKey = "pulseplayer.playback.pauseBetweenLocalFolds"
    static let rewindKey = "pulseplayer.playback.localRewindSeconds"
    static let rewindChoices = [3, 5, 10]
    static let defaultRewind = 10

    static func rewindSeconds(_ stored: Int) -> Int {
        rewindChoices.contains(stored) ? stored : defaultRewind
    }

    static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    static func speed(_ stored: Double) -> Float {
        let rate = Float(stored)
        return speeds.contains(rate) ? rate : 1
    }

    static func label(_ rate: Float, locale: Locale) -> String {
        "\(rate.formatted(.number.locale(locale)))×"
    }
}

struct LocalPlaybackPosition: Codable {
    let seconds: Double
    let duration: Double
    fileprivate let updatedAt: Date

    var fraction: Double { duration > 0 ? min(1, max(0, seconds / duration)) : 0 }
    var resumeSeconds: Double? { seconds > 0 && seconds < duration - 1 ? seconds : nil }
}

@MainActor
final class LocalPlaybackResume: ObservableObject {
    nonisolated static let enabledKey = "foldot.playback.resumeLocalVideos"
    static let shared = LocalPlaybackResume()

    private static let positionsKey = "foldot.playback.localPositions.v1"
    @Published private var positions: [LocalPlaybackIdentity: LocalPlaybackPosition]

    private init() {
        positions = UserDefaults.standard.data(forKey: Self.positionsKey)
            .flatMap { try? JSONDecoder().decode([LocalPlaybackIdentity: LocalPlaybackPosition].self, from: $0) } ?? [:]
        if positions.removeValue(forKey: .movie(LibraryStore.retiredSampleID)) != nil,
           let data = try? JSONEncoder().encode(positions) {
            UserDefaults.standard.set(data, forKey: Self.positionsKey)
        }
    }

    func position(for movie: PracticeRecording) -> LocalPlaybackPosition? { positions[.movie(movie.id)] }
    func position(for video: OfflineVideo) -> LocalPlaybackPosition? {
        positions[.download(owner: video.owner, id: video.id)]
    }

    fileprivate func resumeSeconds(for identity: LocalPlaybackIdentity) -> Double? {
        positions[identity]?.resumeSeconds
    }

    fileprivate func record(_ seconds: Double, duration: Double, for identity: LocalPlaybackIdentity) {
        guard seconds.isFinite, duration.isFinite, duration > 0 else { return }
        let elapsed = min(max(0, seconds), duration)
        guard positions[identity]?.seconds != elapsed || positions[identity]?.duration != duration else { return }
        var next = positions
        next[identity] = LocalPlaybackPosition(seconds: elapsed, duration: duration, updatedAt: .now)
        if next.count > 300, let oldest = next.min(by: { $0.value.updatedAt < $1.value.updatedAt }) {
            next.removeValue(forKey: oldest.key)
        }
        guard let data = try? JSONEncoder().encode(next) else { return }
        UserDefaults.standard.set(data, forKey: Self.positionsKey)
        positions = next
    }
}

// Progress ticks belong to the scrubber, not the entire video/control hierarchy.
@MainActor
final class PlaybackTimeline: ObservableObject {
    @Published var elapsed: Double = 0
    @Published var duration: Double = 0
}

struct FoldGuidePlayback {
    static let playCounts = [1, 2, 3]
    static let preferenceKey = "pulseplayer.practice.playsPerFold"
    let stepID: UUID
    let playsPerFold: Int
    var pass = 1
}

@MainActor
final class PlaybackController: ObservableObject {
    let player = AVPlayer()
    @Published var isPlaying = false
    @Published var isLoading = true
    @Published var error: String?
    @Published private(set) var presentationSize = CGSize.zero
    let timeline = PlaybackTimeline()
    @Published var muted = false
    @Published var speed: Float = 1
    @Published private(set) var repeatedRange: ClosedRange<Double>?
    @Published private(set) var foldGuide: FoldGuidePlayback?
    @Published private(set) var foldNotice: String?
    private var pausedAtRangeEnd = false
    private(set) var loadedURL: URL?
    var intendsPlayback: Bool { wantsPlayback }
    private var status: NSKeyValueObservation?
    private var presentationSizeObservation: NSKeyValueObservation?
    private var timeStatus: NSKeyValueObservation?
    private var playerStatus: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var timer: Any?
    @Published private var wantsPlayback = false
    private var warming = false
    private var generation = UUID()
    private var pendingSeek: Double?
    private var seeking = false
    private var foldPracticeID: FoldPracticeID?
    private var notedPracticeVisit = false
    private var localIdentity: LocalPlaybackIdentity?
    private var pendingLocalResume: Double?
    private var lastLocalSave: ContinuousClock.Instant?
    private var lastSavedLocalTime: Double?
    private var reachedEnd = false
    private var loopsWholeVideo = false
    private var nonLocalSpeed: Float = 1
    private var loadingDeadline: Task<Void, Never>?
    private var initialWatchCompletion: ((Bool) -> Void)?
    private let diagnostics = Logger(subsystem: "app.pulseplayer", category: "Playback")

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        timer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let item = self.player.currentItem else { return }
                // Read current state, rather than a time captured before an item switch.
                let seconds = self.player.currentTime().seconds
                let length = item.duration.seconds
                let elapsed = seconds.isFinite ? max(0, seconds) : 0
                let duration = length.isFinite ? max(0, length) : 0
                if !self.seeking, self.timeline.elapsed != elapsed { self.timeline.elapsed = elapsed }
                if self.timeline.duration != duration { self.timeline.duration = duration }
                if self.isPlaying {
                    self.saveLocalProgress()
                    if !self.seeking, self.pendingSeek == nil, self.repeatedRange == nil, let id = self.foldPracticeID {
                        FoldPracticeStore.shared.follow(elapsed, in: id)
                    }
                }
            }
        }
        timeStatus = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.updatePlaybackState() }
        }
        playerStatus = player.observe(\.status, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.prerollIfReady() }
        }
    }
    func load(_ url: URL, autoplay: Bool, initialWatchCompletion: ((Bool) -> Void)? = nil) {
        release()
        self.initialWatchCompletion = initialWatchCompletion
        loadedURL = url
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        isLoading = true
        if wantsPlayback != autoplay { wantsPlayback = autoplay }
        // Zero leaves buffering/variant selection to AVFoundation for the active video.
        item.preferredForwardBufferDuration = 0
        player.replaceCurrentItem(with: item)
        let token = generation
        presentationSizeObservation = item.observe(\.presentationSize, options: [.initial, .new]) { [weak self] observed, _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.player.currentItem === observed else { return }
                let size = observed.presentationSize
                if self.presentationSize != size { self.presentationSize = size }
            }
        }
        status = item.observe(\.status, options: [.initial, .new]) { [weak self] observed, _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.player.currentItem === observed else { return }
                if observed.status == .failed {
                    self.failMedia("item", underlying: observed.error,
                                   onlineMessage: "This online video could not be played. Check the link or try again.")
                } else if observed.status == .readyToPlay {
                    let duration = observed.duration.seconds
                    if duration.isFinite && duration > 0 { self.timeline.duration = duration }
                    if self.pendingSeek == nil { self.restoreLocalPosition() }
                    if self.pendingSeek != nil { self.performPendingSeek() }
                    else if self.wantsPlayback { self.play() }
                    else { self.prerollIfReady() }
                }
                self.updatePlaybackState()
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] notification in
            guard let ended = notification.object as? AVPlayerItem else { return }
            let endedAt = ended.forwardPlaybackEndTime
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, !self.seeking, self.pendingSeek == nil,
                      let item = self.player.currentItem else { return }
                // A queued end can arrive after the user changes or clears the fold interval.
                let activeEnd = item.forwardPlaybackEndTime
                guard endedAt.isValid == activeEnd.isValid,
                      !endedAt.isValid || CMTimeCompare(endedAt, activeEnd) == 0 else { return }
                if self.repeatedRange != nil {
                    if self.wantsPlayback { self.finishRangePass(allowPracticeBreak: true) }
                    else { self.pausedAtRangeEnd = true }
                } else if let identity = self.localIdentity {
                    if self.loopsWholeVideo, self.wantsPlayback {
                        self.seek(0)
                    } else {
                        let duration = self.player.currentItem?.duration.seconds ?? 0
                        if duration.isFinite, duration > 0 { self.timeline.elapsed = duration }
                        LocalPlaybackResume.shared.record(duration, duration: duration, for: identity)
                        self.reachedEnd = true
                        self.pause()
                    }
                } else if let id = self.foldPracticeID, FoldPracticeStore.shared.entry(for: id) != nil {
                    self.reachedEnd = true
                    self.pause()
                } else {
                    self.seek(0)
                }
            }
        }
        failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] notification in
            let underlying = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.failMedia("interrupted", underlying: underlying,
                               onlineMessage: "Playback was interrupted. Check your connection and try again.")
            }
        }
    }
    func prepare(_ url: URL) {
        guard loadedURL != url else { return }
        load(url, autoplay: false)
        warming = true
        player.currentItem?.preferredForwardBufferDuration = 3
        prerollIfReady()
    }
    private func prerollIfReady() {
        guard warming, !wantsPlayback, player.rate == 0,
              player.status == .readyToPlay, player.currentItem?.status == .readyToPlay else { return }
        warming = false
        // Silent, bounded next-video warmup; never calls play or consumes an allowance.
        player.preroll(atRate: 1) { _ in }
    }
    func play() {
        guard error == nil, player.currentItem != nil else { return }
        if foldNotice != nil { foldNotice = nil }
        if !wantsPlayback { wantsPlayback = true }
        warming = false
        player.cancelPendingPrerolls()
        player.currentItem?.preferredForwardBufferDuration = 0
        guard player.currentItem?.status == .readyToPlay, !seeking else {
            updatePlaybackState()
            return
        }
        if pausedAtRangeEnd {
            finishRangePass(allowPracticeBreak: false)
            return
        }
        if reachedEnd {
            let anchor = FoldPracticeStore.shared.entry(for: foldPracticeID)?.resumeSeconds ?? 0
            seek(anchor < timeline.duration ? anchor : 0)
            return
        }
        do {
            let audio = AVAudioSession.sharedInstance()
            if audio.category != .playback || audio.mode != .moviePlayback {
                try audio.setCategory(.playback, mode: .moviePlayback)
            }
            try audio.setActive(true)
        } catch { fail("Audio playback is unavailable."); return }
        // Unlike playImmediately, this respects automaticallyWaitsToMinimizeStalling.
        player.rate = speed
        updatePlaybackState()
    }
    func pause() {
        finishInitialWatch(played: isPlaying || (wantsPlayback && player.timeControlStatus == .playing))
        saveLocalProgress(force: true)
        if wantsPlayback { wantsPlayback = false }
        warming = false
        player.cancelPendingPrerolls()
        player.pause()
        player.currentItem?.preferredForwardBufferDuration = 3
        updatePlaybackState()
    }
    func toggle() { wantsPlayback ? pause() : play() }
    func setMuted(_ value: Bool) { muted = value; player.isMuted = value }
    func setSpeed(_ value: Float) {
        guard value.isFinite, value > 0 else { return }
        if localIdentity == nil { nonLocalSpeed = value }
        guard speed != value else { return }
        speed = value
        if wantsPlayback { play() }
    }

    func configureLocalPlayback(speed: Float, loops: Bool) {
        guard localIdentity != nil else { return }
        loopsWholeVideo = loops
        if self.speed != speed { setSpeed(speed) }
    }

    func enableLocalProgress(for identity: LocalPlaybackIdentity, resumesPlayback: Bool) {
        guard loadedURL?.isFileURL == true, localIdentity == nil else { return }
        localIdentity = identity
        if resumesPlayback { pendingLocalResume = LocalPlaybackResume.shared.resumeSeconds(for: identity) }
        restoreLocalPosition()
    }

    private func restoreLocalPosition() {
        guard let item = player.currentItem, item.status == .readyToPlay,
              let seconds = pendingLocalResume else { return }
        pendingLocalResume = nil
        let duration = item.duration.seconds
        guard duration.isFinite, seconds < duration - 1 else { return }
        seek(seconds)
    }

    private func saveLocalProgress(force: Bool = false, allowsStart: Bool = false) {
        guard let identity = localIdentity, !reachedEnd, !seeking, pendingSeek == nil,
              pendingLocalResume == nil, let item = player.currentItem else { return }
        let now = ContinuousClock.now
        if !force, let lastLocalSave, lastLocalSave.duration(to: now) < .seconds(5) { return }
        let time = player.currentTime().seconds
        let duration = item.duration.seconds
        guard time.isFinite, (time > 0 || allowsStart), duration.isFinite, duration > 0,
              time != lastSavedLocalTime else { return }
        LocalPlaybackResume.shared.record(time, duration: duration, for: identity)
        lastSavedLocalTime = time
        lastLocalSave = now
    }
    // Attach only to the admitted, active item. A preroll never restores or writes a notebook.
    func enableFoldPractice(for id: FoldPracticeID) {
        guard foldPracticeID != id else { return }
        stopRepeating()
        foldPracticeID = id
        notedPracticeVisit = false
        if let entry = FoldPracticeStore.shared.entry(for: id) { seek(entry.resumeSeconds) }
    }

    var foldPosition: Double? {
        guard let item = player.currentItem, item.status == .readyToPlay,
              !seeking, pendingSeek == nil, error == nil else { return nil }
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? max(0, seconds) : nil
    }

    func playRepeating(_ range: ClosedRange<Double>) {
        guard player.currentItem != nil else { return }
        pause()
        prepareRepeat(range)
        play()
    }

    // A sheet can prepare a range while paused. Its presenter handles watch admission and resuming.
    func prepareRepeat(_ range: ClosedRange<Double>) {
        stopRepeating()
        setPlaybackRange(range)
    }

    func prepareFoldGuide(for id: FoldPracticeID, playsPerFold: Int) throws {
        guard foldPracticeID == id, player.currentItem?.status == .readyToPlay, error == nil,
              let entry = FoldPracticeStore.shared.entry(for: id), let step = entry.currentStep,
              let range = entry.loopRange(for: step, duration: timeline.duration) else {
            throw PulsePlayerError.service("Check the marks for this fold and try again.")
        }
        try FoldPracticeStore.shared.select(step, in: id)
        stopRepeating()
        foldGuide = FoldGuidePlayback(stepID: step.id, playsPerFold: playsPerFold)
        setPlaybackRange(range)
    }

    private func setPlaybackRange(_ range: ClosedRange<Double>) {
        guard let item = player.currentItem else { return }
        repeatedRange = range
        item.forwardPlaybackEndTime = CMTime(seconds: range.upperBound, preferredTimescale: 600)
        movePlayhead(to: range.lowerBound)
    }

    private func finishRangePass(allowPracticeBreak: Bool) {
        pausedAtRangeEnd = false
        guard let range = repeatedRange else { return }
        guard var guide = foldGuide else {
            movePlayhead(to: range.lowerBound)
            return
        }
        guard let id = foldPracticeID, let entry = FoldPracticeStore.shared.entry(for: id),
              entry.selectedID == guide.stepID,
              let index = entry.steps.firstIndex(where: { $0.id == guide.stepID }) else {
            finishFoldGuide("Check the marks for this fold and try again.")
            return
        }
        if guide.pass < guide.playsPerFold {
            guide.pass += 1
            foldGuide = guide
            movePlayhead(to: range.lowerBound)
            return
        }
        guard let next = entry.steps.dropFirst(index + 1).first else {
            finishFoldGuide("You’ve reached the last fold.")
            return
        }
        guard let nextRange = entry.loopRange(for: next, duration: timeline.duration) else {
            finishFoldGuide("Check the marks for this fold and try again.")
            return
        }
        if allowPracticeBreak, localIdentity != nil, UserDefaults.standard.bool(forKey: LocalPlaybackPreferences.pauseBetweenFoldsKey) {
            pausedAtRangeEnd = true
            pause()
            foldNotice = "Tap play when you’re ready for the next fold."
            return
        }
        do {
            try FoldPracticeStore.shared.select(next, in: id)
            foldGuide = FoldGuidePlayback(stepID: next.id, playsPerFold: guide.playsPerFold)
            setPlaybackRange(nextRange)
        } catch {
            finishFoldGuide(error.localizedDescription)
        }
    }

    private func finishFoldGuide(_ message: String) {
        pause()
        stopRepeating()
        reachedEnd = true
        foldNotice = message
    }

    func stopRepeating() {
        pausedAtRangeEnd = false
        if foldGuide != nil { foldGuide = nil }
        if foldNotice != nil { foldNotice = nil }
        guard repeatedRange != nil else { return }
        repeatedRange = nil
        player.currentItem?.forwardPlaybackEndTime = .invalid
    }

    func seek(_ seconds: Double) {
        guard seconds.isFinite, player.currentItem != nil else { return }
        if foldGuide != nil || foldNotice != nil { stopRepeating() }
        movePlayhead(to: seconds)
    }

    private func movePlayhead(to seconds: Double) {
        pausedAtRangeEnd = false
        pendingLocalResume = nil
        reachedEnd = false
        if let range = repeatedRange, seconds < range.lowerBound || seconds >= range.upperBound {
            stopRepeating()
        }
        let length = player.currentItem?.duration.seconds ?? 0
        pendingSeek = max(0, length.isFinite && length > 0 ? min(seconds, length) : seconds)
        player.pause()
        player.cancelPendingPrerolls()
        performPendingSeek()
    }
    private func performPendingSeek() {
        guard !seeking, let item = player.currentItem, item.status == .readyToPlay, let requested = pendingSeek else { return }
        let duration = item.duration.seconds
        let target = duration.isFinite && duration > 0 ? min(requested, duration) : requested
        pendingSeek = nil
        seeking = true
        let token = generation
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.seeking = false
                if self.pendingSeek != nil { self.performPendingSeek() }
                else {
                    if finished {
                        self.timeline.elapsed = target
                        if self.repeatedRange == nil, let id = self.foldPracticeID {
                            FoldPracticeStore.shared.follow(target, in: id)
                        }
                        self.saveLocalProgress(force: true, allowsStart: true)
                        if self.localIdentity != nil, self.repeatedRange == nil,
                           self.timeline.duration > 0, target >= self.timeline.duration {
                            self.reachedEnd = true
                            if !self.loopsWholeVideo { self.pause(); return }
                        }
                    }
                    if self.wantsPlayback { self.play() }
                }
            }
        }
    }
    private func updatePlaybackState() {
        let playing = error == nil && wantsPlayback && player.timeControlStatus == .playing
        if playing {
            finishInitialWatch(played: true)
            if let id = foldPracticeID, !notedPracticeVisit {
                notedPracticeVisit = true
                FoldPracticeStore.shared.markOpened(id)
            }
        }
        let loading = error == nil && player.currentItem != nil &&
            (player.currentItem?.status == .unknown || (wantsPlayback && player.timeControlStatus == .waitingToPlayAtSpecifiedRate))
        if isPlaying != playing { isPlaying = playing }
        if isLoading != loading { isLoading = loading }
        if loading, wantsPlayback, loadingDeadline == nil {
            let token = generation
            loadingDeadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                guard let self, self.generation == token, self.wantsPlayback, self.isLoading else { return }
                self.failMedia("timeout", underlying: nil,
                               onlineMessage: "This video is taking too long to load. Check your connection and retry.")
            }
        } else if !loading || !wantsPlayback {
            loadingDeadline?.cancel()
            loadingDeadline = nil
        }
    }
    func trackInitialWatch(_ completion: ((Bool) -> Void)?) {
        finishInitialWatch(played: isPlaying)
        initialWatchCompletion = completion
    }
    private func finishInitialWatch(played: Bool) {
        let completion = initialWatchCompletion
        initialWatchCompletion = nil
        completion?(played)
    }
    private func failMedia(_ stage: String, underlying: Error?, onlineMessage: String) {
        let failure = underlying.map { $0 as NSError }
        var source = "online"
        var message = onlineMessage
        if let url = loadedURL, url.isFileURL {
            let readable = FileManager.default.isReadableFile(atPath: url.path)
            source = readable ? "local-readable" : "local-unreadable"
            message = readable ? "This clip could not be played." : "This video file is missing or unreadable. Open it again or download a new copy."
        }
        let cause = failure?.userInfo[NSUnderlyingErrorKey] as? NSError
        diagnostics.error("Playback failed; stage=\(stage, privacy: .public), source=\(source, privacy: .public), domain=\(failure?.domain ?? "none", privacy: .public), code=\(failure?.code ?? 0), causeDomain=\(cause?.domain ?? "none", privacy: .public), causeCode=\(cause?.code ?? 0)")
        if #available(iOS 27, *), let item = player.currentItem {
            let diagnostics = self.diagnostics
            item.fetchErrorLog { log in
                if let event = log?.events.last {
                    diagnostics.error("Media response; domain=\(event.errorDomain, privacy: .public), code=\(event.errorStatusCode)")
                }
            }
        }
        fail(message)
    }
    private func fail(_ message: String) {
        pause()
        stopRepeating()
        error = message
        isLoading = false
    }
    func release() {
        generation = UUID()
        pause()
        stopRepeating()
        status = nil
        presentationSizeObservation = nil
        if presentationSize != .zero { presentationSize = .zero }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        endObserver = nil
        failureObserver = nil
        pendingSeek = nil
        seeking = false
        if localIdentity != nil, speed != nonLocalSpeed { speed = nonLocalSpeed }
        foldPracticeID = nil
        localIdentity = nil
        pendingLocalResume = nil
        lastLocalSave = nil
        lastSavedLocalTime = nil
        reachedEnd = false
        loopsWholeVideo = false
        player.currentItem?.cancelPendingSeeks()
        player.replaceCurrentItem(with: nil)
        loadedURL = nil
        timeline.elapsed = 0
        timeline.duration = 0
        error = nil
        isLoading = false
    }
    deinit {
        loadingDeadline?.cancel()
        if let timer { player.removeTimeObserver(timer) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
    }
}

// Screen-owned: current, previous and next only. No disk download/cache or quota writes.
@MainActor
final class PlaybackPool: ObservableObject {
    @Published private(set) var controllers: [String: PlaybackController] = [:]
    private var selectedID: String?
    private var nextEntry: PlaybackQueueEntry?
    private var warmupTask: Task<Void, Never>?
    private var warmupID: String?

    func update(clips: [LessonClip], selectedID: String?) {
        update(entries: clips.map { PlaybackQueueEntry(id: $0.id, clip: $0) }, selectedID: selectedID)
    }
    func update(entries: [PlaybackQueueEntry], selectedID: String?) {
        guard let selectedID, let index = entries.firstIndex(where: { $0.id == selectedID }) else {
            releaseAll()
            return
        }
        if self.selectedID != selectedID { cancelWarmup() }
        self.selectedID = selectedID
        nextEntry = entries.indices.contains(index + 1) ? entries[index + 1] : nil
        let nearby = entries[max(0, index - 1)...min(entries.count - 1, index + 1)]
        let ids = Set(nearby.map(\.id))
        for (id, controller) in controllers {
            if !ids.contains(id) { controller.release() }
            else if id != selectedID, controller.intendsPlayback { controller.pause() }
        }
        var retained: [String: PlaybackController] = [:]
        for entry in nearby {
            let controller = controllers[entry.id] ?? PlaybackController()
            if let url = controller.loadedURL, url != entry.clip.playbackURL { controller.release() }
            retained[entry.id] = controller
        }
        guard let current = retained[selectedID] else { return }
        // Appending a feed batch should not invalidate every visible video page.
        if controllers.count != retained.count || retained.contains(where: { controllers[$0.key] !== $0.value }) {
            controllers = retained
        }
        if current.isPlaying { prepareNext(after: selectedID) }
    }
    func prepareNext(after id: String) {
        guard id == selectedID, controllers[id]?.isPlaying == true,
              let nextEntry, nextEntry.clip.playbackURL.isFileURL,
              let upcoming = controllers[nextEntry.id],
              upcoming.loadedURL != nextEntry.clip.playbackURL else { return }
        guard warmupID != nextEntry.id else { return }
        cancelWarmup()
        warmupID = nextEntry.id
        warmupTask = Task { [weak self] in
            // Let the current stream establish its buffer before competing for bandwidth.
            // These thresholds are app policy, not guarantees from AVFoundation.
            for _ in 0..<24 {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self, self.selectedID == id, self.nextEntry?.id == nextEntry.id,
                      let current = self.controllers[id], current.isPlaying else { return }
                guard let item = current.player.currentItem else { return }
                let position = current.player.currentTime().seconds
                let duration = item.duration.seconds
                let ahead = item.loadedTimeRanges.reduce(0.0) { longest, value in
                    let range = value.timeRangeValue
                    let start = range.start.seconds
                    let end = CMTimeRangeGetEnd(range).seconds
                    guard start.isFinite, end.isFinite, position >= start, position <= end else { return longest }
                    return max(longest, end - position)
                }
                let remaining = duration.isFinite ? max(0, duration - position) : 4
                guard position.isFinite, item.isPlaybackLikelyToKeepUp,
                      ahead >= min(4, remaining) else { continue }
                self.controllers[nextEntry.id]?.prepare(nextEntry.clip.playbackURL)
                return
            }
        }
    }
    private func cancelWarmup() {
        warmupTask?.cancel()
        warmupTask = nil
        warmupID = nil
    }
    func suspend() {
        cancelWarmup()
        // The active page records its resume intent before pausing itself.
        for (id, controller) in controllers where id != selectedID { controller.pause() }
    }
    func trimMemory() {
        cancelWarmup()
        for (id, controller) in controllers where id != selectedID { controller.release() }
        controllers = controllers.filter { $0.key == selectedID }
    }
    func releaseAll() {
        cancelWarmup()
        controllers.values.forEach { $0.release() }
        controllers = [:]
        selectedID = nil
        nextEntry = nil
    }
    deinit { warmupTask?.cancel() }
}

struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer
    var fill = true
    var onReadyForDisplay: ((Bool) -> Void)?
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        let coordinator = context.coordinator
        coordinator.onReadyForDisplay = onReadyForDisplay
        coordinator.observation = view.playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak coordinator] layer, _ in
            Task { @MainActor [weak coordinator, weak layer] in
                guard let layer else { return }
                coordinator?.onReadyForDisplay?(layer.isReadyForDisplay)
            }
        }
        return view
    }
    func updateUIView(_ view: PlayerLayerView, context: Context) {
        context.coordinator.onReadyForDisplay = onReadyForDisplay
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        let gravity: AVLayerVideoGravity = fill ? .resizeAspectFill : .resizeAspect
        if view.playerLayer.videoGravity != gravity { view.playerLayer.videoGravity = gravity }
    }
    static func dismantleUIView(_ view: PlayerLayerView, coordinator: Coordinator) {
        coordinator.observation = nil
        coordinator.onReadyForDisplay = nil
        view.playerLayer.player = nil
    }
    final class Coordinator {
        var observation: NSKeyValueObservation?
        var onReadyForDisplay: ((Bool) -> Void)?
    }
}
final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
func durationLabel(_ seconds: Double, fractional: Bool = false) -> String {
    let safe = seconds.isFinite ? max(0, seconds) : 0
    let bounded = min(safe, 359999)
    if fractional {
        let ticks = Int((bounded * 100).rounded())
        let number = ticks / 100
        return String(format: "%d:%02d.%02d", number / 60, number % 60, ticks % 100)
    }
    let number = Int(bounded)
    return String(format: "%d:%02d", number / 60, number % 60)
}
