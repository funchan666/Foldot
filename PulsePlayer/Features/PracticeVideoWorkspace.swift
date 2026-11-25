import SwiftUI
import AVFoundation
import ImageIO
import PhotosUI
import UniformTypeIdentifiers

enum VideoTool: String, Identifiable, CaseIterable {
    case audio, speed, frame, studio, ranges
    var id: String { rawValue }
    var title: String {
        switch self {
        case .audio: return "Extract audio"
        case .speed: return "Change speed"
        case .frame: return "Reframe video"
        case .studio: return "Edit video"
        case .ranges: return "Mark a range"
        }
    }
    var glyph: PulsePlayerGlyph {
        switch self {
        case .audio: return .sound
        case .speed: return .play
        case .frame: return .feed
        case .studio: return .edit
        case .ranges: return .bookmark
        }
    }
}

struct ToolsView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @ObservedObject private var notebook = FoldPracticeStore.shared
    let openPlus: () -> Void
    @State private var chosenID: UUID?
    @State private var measuredDuration: (movieID: UUID, seconds: Double)?
    @State private var sheet: ToolSheet?
    @State private var playback: PlayerRoute?
    @State private var importing = false

    private enum ToolSheet: Identifiable {
        case sources
        case editor(VideoTool, PracticeRecording?)
        case frames(RangeFrameRequest)

        var id: String {
            switch self {
            case .sources: return "sources"
            case .editor(let tool, let movie): return tool.id + (movie?.id.uuidString ?? "")
            case .frames(let request): return request.id.uuidString
            }
        }
    }

    private var videos: [PracticeRecording] {
        library.movies.filter { !$0.isAudio }.sorted { ($0.lastOpenedAt ?? $0.date) > ($1.lastOpenedAt ?? $1.date) }
    }

    var body: some View {
        let movie = videos.first { $0.id == chosenID }
            ?? videos.first { notebook.entry(for: .movie($0.id)) != nil } ?? videos.first
        ScenePage { _ in
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    IconButton(symbol: .back, label: "Back", glass: true) { dismiss() }
                    Spacer()
                    PlusEntryButton(action: openPlus)
                }
                SceneTitle("Fold workbench", size: 32)
                if let movie {
                    Text(verbatim: movie.displayFilename).font(.headline).accessibilityAddTraits(.isHeader)
                    ActionButton(title: "Change video", primary: false) { sheet = .sources }
                    if let entry = notebook.entry(for: .movie(movie.id)),
                       let duration = entry.duration ?? entry.clip.duration ?? (measuredDuration?.movieID == movie.id ? measuredDuration?.seconds : nil) {
                        LocalizedText("Compare the paper before and after a fold.")
                            .foregroundStyle(PulsePlayerStyle.secondary)
                        ForEach(Array(entry.steps.enumerated()), id: \.element.id) { index, step in
                            if let range = entry.loopRange(for: step, duration: duration) {
                                let name = step.displayName(language: .from(locale))
                                    ?? L10n.format("Fold %@", [String(index + 1)], language: .from(locale))
                                Button {
                                    let mark = VideoRangeMark(id: step.id, name: name, start: range.lowerBound, end: range.upperBound)
                                    sheet = .frames(RangeFrameRequest(source: library.url(for: movie), mark: mark))
                                } label: {
                                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                                        Text(verbatim: durationLabel(step.start)).monospacedDigit()
                                            .foregroundStyle(PulsePlayerStyle.secondary)
                                            .environment(\.layoutDirection, .leftToRight)
                                        Text(verbatim: name).multilineTextAlignment(.leading)
                                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                        .contentShape(Rectangle())
                                }.buttonStyle(PressStyle())
                                Divider()
                            }
                        }
                    } else {
                        if notebook.entry(for: .movie(movie.id)) == nil {
                            LocalizedText("Mark a fold in the player to compare its frames here.")
                        }
                        ActionButton(title: "Open in player") {
                            if let route = PlayerRoute.localMovies([movie], selected: movie, library: library) {
                                playback = route
                            } else { library.error = "This video file is no longer available." }
                        }
                    }
                    SectionLabel(title: "Edit video")
                    ForEach([VideoTool.studio, .ranges, .speed, .frame, .audio]) { tool in
                        EditorCommand(title: tool.title, symbol: tool.glyph, expanded: true) {
                            sheet = .editor(tool, movie)
                        }
                    }
                } else {
                    ActionButton(title: "Choose a video") { sheet = .sources }
                }
            }
        }
        .task(id: movie?.id) {
            measuredDuration = nil
            guard let movie, let entry = notebook.entry(for: .movie(movie.id)),
                  entry.duration == nil, entry.clip.duration == nil else { return }
            let asset = AVURLAsset(url: library.url(for: movie))
            if let duration = try? await editableVideoDuration(for: asset), !Task.isCancelled {
                measuredDuration = (movie.id, duration)
            }
        }
        .fullScreenCover(item: $playback) { PlayerScreen(route: $0) }
        .sheet(item: $sheet) { route in
            switch route {
            case .frames(let request): RangeFrameComparison(request: request)
            case .editor(let tool, let movie): EditorSheet(initialMovie: movie, initialTool: tool)
            case .sources: sources
            }
        }
    }

    private var sources: some View {
        VStack(spacing: 0) {
            SheetHeading(title: "Choose a video") { sheet = nil }.disabled(importing)
            ScenePage { geometry in
                VStack(alignment: .leading, spacing: 14) {
                    VideoImportActions(onImported: choose, importing: $importing,
                                       presentation: .sourcePair(stacked: PulsePlayerStyle.pageContentWidth(in: geometry) < 320))
                    ForEach(videos) { movie in
                        Button { choose(movie) } label: {
                            Text(verbatim: movie.displayFilename)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                        }.buttonStyle(PressStyle()).disabled(importing)
                        Divider()
                    }
                }
            }
        }.interactiveDismissDisabled(importing)
            .pulsePlayerScreenBackground().foregroundStyle(PulsePlayerStyle.paper)
    }

    private func choose(_ movie: PracticeRecording) {
        chosenID = movie.id
        sheet = nil
    }
}

struct EditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    var initialMovie: PracticeRecording? = nil
    var initialTool: VideoTool = .studio
    @StateObject private var departure = ExportDeparture()
    var body: some View {
        EditorWorkspace(initialMovie: initialMovie, initialTool: initialTool) {
            departure.request { dismiss() }
        }
            .environmentObject(departure)
            .modifier(ExportDepartureProtection(departure: departure))
    }
}
struct EditorWorkspace: View {
    @EnvironmentObject private var commerce: CommerceStore
    @State private var showingExportMembership = false
    @EnvironmentObject private var departure: ExportDeparture
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var ads: RewardedAds
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @FocusState private var editingRangeName: Bool
    let initialTool: VideoTool
    let close: () -> Void
    @StateObject private var editor = VideoEditor()
    @State private var selected: PracticeRecording?
    @ObservedObject private var notebook = FoldPracticeStore.shared
    @Environment(\.locale) private var locale
    @State private var choosingFoldTrim = false
    @State private var rangeNameDraft = ""
    @State private var activeLoop: VideoRangeMark?
    @State private var showingRanges: Bool
    @State private var frameComparison: RangeFrameRequest?
    @State private var importing = false
    @State private var error: String?
    @State private var shareURL: SharedFile?
    @State private var savedExport: PracticeRecording?
    @State private var sharingExport = false
    @State private var shareTask: Task<Void, Never>?
    @State private var playbackScrubbing = false
    @State private var showingFullScreenPreview = false
    @State private var inlinePreviewAttached = true
    @State private var resumePreview = false
    @State private var retryID = UUID()
    @State private var openedRequest: VideoOpenRequest?
    @State private var stage: Stage
    @State private var output: Output
    @State private var exportTask: Task<Void, Never>?

    private enum Stage: String, CaseIterable {
        case interval = "Clip range", adjustments = "Adjust", delivery = "Export"
    }

    private enum Output: String, CaseIterable {
        case movie = "MP4", audio = "M4A"
    }

    private var previewRange: ClosedRange<Double> { editor.recipe.start...max(editor.recipe.start, editor.recipe.end) }
    private var editingLocked: Bool {
        departure.running || editor.isExporting || editor.isPreparingPreview || sharingExport
    }
    private var canPlay: Bool {
        scenePhase == .active && !ads.isPresenting && shareURL == nil
            && !showingExportMembership && frameComparison == nil
    }
    private var operationError: String? {
        guard !departure.running else { return nil }
        return error ?? (editor.duration > 0 ? editor.error : nil)
    }

    init(initialMovie: PracticeRecording? = nil, initialTool: VideoTool = .studio, close: @escaping () -> Void) {
        self.initialTool = initialTool
        self.close = close
        _selected = State(initialValue: initialMovie)
        _stage = State(initialValue: (initialTool == .frame || initialTool == .speed) ? .adjustments : .interval)
        _output = State(initialValue: initialTool == .audio ? .audio : .movie)
        _showingRanges = State(initialValue: initialTool == .ranges)
    }
    var body: some View {
        ScrollViewReader { scroll in
            workspace(scroll)
                .onChange(of: savedExport?.id) { _, id in
                    if let id { scroll.scrollTo(id, anchor: .bottom) }
                }
                .onChange(of: operationError) { _, message in
                    if message != nil { scroll.scrollTo("editor-feedback", anchor: .bottom) }
                }
        }
    }

    private func workspace(_ scroll: ScrollViewProxy) -> some View {
        let openRequest = VideoOpenRequest(movieID: selected?.id, retryID: retryID)
        return GeometryReader { container in
            let width = PulsePlayerStyle.pageContentWidth(in: container)
            let bounds = CGRect(origin: .zero, size: container.size)
            let narrow = width < 370 || typeSize > .xLarge
            let spread = width > 780 && !narrow && !PulsePlayerStyle.intersectsReservedRegion(bounds, in: container)
            let layout = spread ? AnyLayout(HStackLayout(alignment: .top, spacing: 24))
                                : AnyLayout(VStackLayout(alignment: .leading, spacing: 18))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    fileHeading.id("editor-top")
                    if let selected {
                        layout {
                            previewStage(height: min(430, max(128, container.size.height * 0.38)), scroll: scroll)
                            if editor.duration > 0 {
                                editingSteps(for: selected, narrow: narrow || spread, scroll: scroll)
                                    .frame(maxWidth: spread ? 380 : .infinity, alignment: .leading)
                            }
                        }
                    } else {
                        importContent(in: container)
                    }
                }
                .frame(maxWidth: spread ? 1120 : 730, alignment: .leading)
                .frame(maxWidth: .infinity)
                .pageHorizontalMargins()
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
        }
            .pulsePlayerScreenBackground()
            .foregroundStyle(PulsePlayerStyle.paper)
            .dismissKeyboardOnOutsideTap($editingRangeName, scope: "editor-range-name")
            .interactiveDismissDisabled(importing || departure.running)
            .sheet(item: $shareURL) { ShareSheet(items: [$0.url]) }
            .fullScreenCover(isPresented: $showingExportMembership) { MembershipView(entry: .media) }
            .fullScreenCover(isPresented: $showingFullScreenPreview, onDismiss: {
                inlinePreviewAttached = true
            }) {
                EditorFullScreenPreview(playback: editor.preview, retry: editor.retryPlayback)
            }
            .sheet(item: $frameComparison) { request in RangeFrameComparison(request: request) }
            .onChange(of: selected?.id) { _, _ in
                activeLoop = nil
                choosingFoldTrim = false
                rangeNameDraft = ""
                showingRanges = initialTool == .ranges
                stage = (initialTool == .frame || initialTool == .speed) ? .adjustments : .interval
                scroll.scrollTo("editor-top", anchor: .top)
            }
            .onChange(of: stage) { _, next in
                editingRangeName = false
                if next == .interval && !editor.isShowingSource {
                    editor.restoreSourcePreview(seekTo: editor.recipe.start)
                }
            }
            .onChange(of: editor.recipe) { _, _ in
                savedExport = nil
                if !editor.isShowingSource { editor.restoreSourcePreview(seekTo: editor.recipe.start) }
            }
            .task(id: openRequest) {
                guard let selected, openedRequest != openRequest else { return }
                playbackScrubbing = false
                await editor.open(library.url(for: selected)) {
                    openedRequest = openRequest
                    library.markOpened(selected)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { interruptPreview() }
                else if phase == .active { resumePreviewIfPossible() }
            }
            .onChange(of: ads.isPresenting) { _, presenting in
                if presenting { interruptPreview() } else { resumePreviewIfPossible() }
            }
            .onChange(of: showingExportMembership) { _, presenting in if presenting { editor.preview.pause() } }
            .onDisappear {
                guard !showingExportMembership, inlinePreviewAttached, shareURL == nil, frameComparison == nil else { return }
                openedRequest = nil
                editor.close()
                exportTask?.cancel()
                shareTask?.cancel()
            }
    }

    private var fileHeading: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                SceneTitle(selected == nil ? "Choose a video" : initialTool.title, size: 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                IconButton(symbol: .close, label: "Close", glass: true, action: close).disabled(importing)
            }
            if let selected {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { sourceFile(selected); changeVideo.fixedSize() }
                    VStack(alignment: .leading, spacing: 0) { sourceFile(selected); changeVideo }
                }
            }
        }
    }

    private func sourceFile(_ movie: PracticeRecording) -> some View {
        Text(verbatim: movie.displayFilename).font(.capture(.subheadline))
            .foregroundStyle(PulsePlayerStyle.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func importContent(in container: GeometryProxy) -> some View {
        let videos = library.movies.filter { !$0.isAudio }.sorted {
            ($0.lastOpenedAt ?? $0.date) > ($1.lastOpenedAt ?? $1.date)
        }
        let width = PulsePlayerStyle.pageContentWidth(in: container)
        let divided = PulsePlayerStyle.intersectsReservedRegion(CGRect(origin: .zero, size: container.size), in: container)
        return VStack(alignment: .leading, spacing: 14) {
            VideoImportActions(onImported: choose, importing: $importing,
                               presentation: .sourcePair(stacked: width < 330 || divided || typeSize > .xLarge))
            if let error { ErrorNote(message: error).id("editor-feedback") }
            if let libraryError = library.error { ErrorNote(message: libraryError) }
            if !videos.isEmpty {
                SectionLabel(title: "Video files").accessibilityAddTraits(.isHeader)
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(videos) { movie in
                        VideoFileButton(url: library.url(for: movie), filename: movie.displayFilename,
                                        date: movie.lastOpenedAt ?? movie.date) { choose(movie) }
                            .disabled(importing)
                            .accessibilityIdentifier("editor.pick.\(movie.id)")
                        Divider()
                    }
                }
            }
        }
    }

    private func previewStage(height: CGFloat, scroll: ScrollViewProxy) -> some View {
        let compareLoop = activeLoop.map { mark in { compareRange(mark) } }
        let hasRanges = library.movies.first { $0.id == selected?.id }?.rangeMarks?.isEmpty == false
        return VStack(alignment: .leading, spacing: 8) {
            PulsePlayerStyle.mediaBackdrop
                .overlay {
                    if inlinePreviewAttached {
                        VideoSurface(player: editor.preview.player, fill: false)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .overlay {
                    if editor.isLoading || editor.isPreparingPreview {
                        AccountLoadingIndicator(title: editor.isLoading ? "Preparing your video…" : "Preparing preview…")
                            .padding(12)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if editor.duration > 0 && !editor.isLoading {
                        EditorPreviewModeButton(title: "Full screen") {
                            editingRangeName = false
                            inlinePreviewAttached = false
                            showingFullScreenPreview = true
                        }
                        .disabled(!canPlay || editingLocked || playbackScrubbing)
                        .accessibilityIdentifier("editor.enterFullScreen")
                        .padding(8)
                    }
                }
                .clipShape(.rect(cornerRadius: 14))
            if editor.duration > 0 {
                VideoPlaybackControls(playback: editor.preview, timeline: editor.preview.timeline,
                                      enabled: canPlay && !editingLocked,
                                      canResume: canPlay && !editingLocked,
                                      scrubbing: $playbackScrubbing, retry: editor.retryPlayback,
                                      sourceFrames: editor.isShowingSource ? editor.thumbnails : nil,
                                      sourceDuration: editor.duration,
                                      trim: previewRange,
                                      compareLoop: compareLoop,
                                      rangesTitle: hasRanges ? "Saved ranges" : "Mark a range",
                                      openRanges: {
                        guard canPlay, !editingLocked else { return }
                        stage = .interval
                        showingRanges = true
                        Task { @MainActor in
                            await Task.yield()
                            scroll.scrollTo("editor-ranges", anchor: .top)
                        }
                    })
            } else if !editor.isLoading, let error = editor.error {
                VStack(alignment: .leading, spacing: 6) {
                    ErrorNote(message: error)
                    EditorCommand(title: "Retry") { retryID = UUID() }
                }
            }
        }
        .id("editor-preview")
    }

    private func editingSteps(for movie: PracticeRecording, narrow: Bool, scroll: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            FlowChoices(values: Stage.allCases.map(\.rawValue), selected: stage.rawValue) { choice in
                guard let next = Stage(rawValue: choice) else { return }
                stage = next
            }
            .disabled(editingLocked)
            .id("editor-adjustments")
            Divider()
            Group {
                switch stage {
                case .interval:
                    if let entry = notebook.entry(for: .movie(movie.id)) {
                        foldTrimChoices(entry).disabled(editingLocked)
                    }
                    trimControls(stacked: narrow)
                    ClipRangeLoopButton(playback: editor.preview, range: previewRange) {
                        activeLoop = nil
                        editor.playRange(previewRange)
                        scroll.scrollTo("editor-preview", anchor: .top)
                    }.disabled(!canPlay || editingLocked || playbackScrubbing)
                    EditorCommand(title: showingRanges ? "Hide range notes" : "Save or review a range", symbol: .bookmark) {
                        editingRangeName = false
                        showingRanges.toggle()
                    }.disabled(editingLocked)
                    if showingRanges { ranges(for: movie, scroll: scroll) }
                case .adjustments:
                    clipAdjustments
                case .delivery:
                    delivery(for: movie, scroll: scroll)
                }
            }
            if let operationError { ErrorNote(message: operationError).id("editor-feedback") }
            if let savedExport {
                SavedVideoExport(movie: savedExport, sharing: sharingExport, disabled: departure.running) {
                    shareExport(savedExport)
                }.id(savedExport.id)
            }
        }
    }

    private func ranges(for movie: PracticeRecording, scroll: ScrollViewProxy) -> some View {
        VideoRangePanel(playback: editor.preview, movieID: movie.id, duration: editor.duration,
                        start: editor.recipe.start, end: editor.recipe.end, saveAndLoop: initialTool == .ranges, activeLoopID: activeLoop?.id,
                        name: $rangeNameDraft, editingName: $editingRangeName, compareRange: compareRange,
                        playRange: { mark in
            guard let range = mark.timeRange else { return }
            activeLoop = mark
            editor.playRange(range)
            scroll.scrollTo("editor-preview", anchor: .top)
        }, trimToRange: { range in
            applyTrim(range)
            scroll.scrollTo("editor-adjustments", anchor: .top)
        })
        .id(movie.id)
        .disabled(!canPlay || editingLocked)
        .id("editor-ranges")
    }

    private func compareRange(_ mark: VideoRangeMark) {
        guard let selected, canPlay, !editingLocked else { return }
        editingRangeName = false
        editor.preview.pause()
        frameComparison = RangeFrameRequest(source: library.url(for: selected), mark: mark)
    }

    private func interruptPreview() {
        resumePreview = resumePreview || editor.preview.intendsPlayback
        editor.preview.pause()
    }

    private func resumePreviewIfPossible() {
        guard resumePreview, scenePhase == .active, !ads.isPresenting else { return }
        resumePreview = false
        guard selected != nil, canPlay, !departure.running else { return }
        editor.preview.play()
    }

    @ViewBuilder private var changeVideo: some View {
        if !editingLocked {
            EditorCommand(title: "Change video", symbol: .folder) {
                editingRangeName = false
                selected = nil
                error = nil
                savedExport = nil
                editor.close()
            }
        }
    }

    private var clipAdjustments: some View {
        VStack(alignment: .leading, spacing: 10) {
            if initialTool == .frame, output == .movie { framing }
            toolHeading("Video speed")
            FlowChoices(values: ["0.5×", "0.75×", "1×", "1.5×", "2×"], selected: String(format: "%g×", editor.recipe.speed)) {
                if let speed = Double($0.dropLast()) { editor.recipe.speed = speed }
            }
            finalDuration
            if output == .movie {
                if initialTool != .frame { Divider(); framing }
                EditorCommand(title: editor.recipe.muted ? "Audio: Muted" : "Audio: Original",
                              symbol: editor.recipe.muted ? .mute : .sound) { editor.recipe.muted.toggle() }
            }
        }.disabled(editingLocked)
    }

    private var framing: some View {
        VStack(alignment: .leading, spacing: 8) {
            toolHeading("Framing")
            FlowChoices(values: VideoFrame.allCases.map(\.rawValue), selected: editor.recipe.frame.rawValue) {
                if let frame = VideoFrame(rawValue: $0) { editor.recipe.frame = frame }
            }
            framingActions
        }
    }

    private func applyTrim(_ range: ClosedRange<Double>) {
        editor.preview.pause()
        activeLoop = nil
        var recipe = editor.recipe
        recipe.start = range.lowerBound
        recipe.end = range.upperBound
        editor.recipe = recipe
        editor.restoreSourcePreview(seekTo: range.lowerBound)
        stage = .interval
        choosingFoldTrim = false
    }

    @ViewBuilder private func foldTrimChoices(_ entry: FoldPracticeEntry) -> some View {
        EditorCommand(title: choosingFoldTrim ? "Close fold list" : "Trim to a marked fold", symbol: .fold) {
            choosingFoldTrim.toggle()
        }
        if choosingFoldTrim {
            ForEach(Array(entry.steps.enumerated()), id: \.element.id) { index, step in
                if let range = entry.loopRange(for: step, duration: editor.duration) {
                    Button { applyTrim(range) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(verbatim: durationLabel(step.start)).monospacedDigit()
                                .foregroundStyle(PulsePlayerStyle.secondary)
                            if let name = step.displayName(language: .from(locale)) {
                                Text(verbatim: name)
                            } else {
                                LocalizedText("Fold %@", String(index + 1))
                            }
                        }
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }.buttonStyle(PressStyle())
                }
            }
        }
    }

    private func trimControls(stacked: Bool) -> some View {
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                             : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
        return layout {
            trimPoint(start: true)
            trimPoint(start: false)
        }.disabled(editingLocked)
    }

    private func trimPoint(start: Bool) -> some View {
        let label = start ? "Trim start" : "Trim end"
        let position = Binding<Double>(
            get: { start ? editor.recipe.start : editor.recipe.end },
            set: { seconds in
                editor.preview.pause()
                activeLoop = nil
                if start { editor.recipe.start = max(0, min(seconds, editor.recipe.end - 0.1)) }
                else { editor.recipe.end = min(editor.duration, max(seconds, editor.recipe.start + 0.1)) }
                editor.restoreSourcePreview(seekTo: start ? editor.recipe.start : editor.recipe.end)
            })
        return VStack(alignment: .leading, spacing: 2) {
            EditorCommand(title: start ? "Set start" : "Set end") {
                if let seconds = editor.preview.foldPosition { position.wrappedValue = seconds }
            }
            .disabled(!canPlay || !editor.isShowingSource || playbackScrubbing)
            .accessibilityIdentifier(start ? "video.range.setStart" : "video.range.setEnd")
            Text(verbatim: durationLabel(position.wrappedValue, fractional: true))
                .font(.capture(.title3, weight: .semibold)).monospacedDigit()
                .environment(\.layoutDirection, .leftToRight)
            PulsePlayerScrubber(value: position, range: 0...max(0.1, editor.duration), label: label, showsPlayhead: true)
                .background(alignment: .center) { Capsule().fill(PulsePlayerStyle.line).frame(height: 4) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var framingActions: some View {
        let rotate = EditorCommand(title: "Rotate 90° · \((editor.recipe.quarterTurns % 4) * 90)°") {
            editor.recipe.quarterTurns = (editor.recipe.quarterTurns + 1) % 4
        }
        let mirror = EditorCommand(title: editor.recipe.mirrored ? "Mirror: On" : "Mirror: Off") {
            editor.recipe.mirrored.toggle()
        }
        return PulsePlayerGlassGroup {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) {
                    rotate.fixedSize()
                    mirror.fixedSize()
                }
                VStack(alignment: .leading, spacing: 2) {
                    rotate
                    mirror
                }
            }
        }
    }

    private var finalDuration: some View {
        LocalizedText("Final duration · \(durationLabel((editor.recipe.end - editor.recipe.start) / editor.recipe.speed))")
            .font(.capture(.footnote, weight: .semibold))
            .foregroundStyle(PulsePlayerStyle.accent)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func toolHeading(_ title: String) -> some View {
        LocalizedText(title).font(.capture(.headline))
            .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
    }

    private func toolNote(_ message: String) -> some View {
        LocalizedText(message).font(.capture(.footnote)).foregroundStyle(PulsePlayerStyle.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func delivery(for movie: PracticeRecording, scroll: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            toolHeading("File format")
            FlowChoices(values: Output.allCases.map(\.rawValue), selected: output.rawValue) {
                guard let format = Output(rawValue: $0), format != output else { return }
                output = format
                savedExport = nil
                editor.restoreSourcePreview(seekTo: editor.recipe.start)
            }.disabled(editingLocked)
            if output == .movie {
                toolHeading("Resolution")
                FlowChoices(values: ExportQuality.allCases.map(\.rawValue), selected: editor.recipe.quality.rawValue) {
                    if let quality = ExportQuality(rawValue: $0) { editor.recipe.quality = quality }
                }
                .accessibilityIdentifier("editor.exportSettings")
                .disabled(editingLocked)
            } else {
                toolNote("Audio extraction uses your trim and speed settings.")
            }
            finalDuration
            if departure.running {
                ProgressView(value: Double(editor.progress)).tint(PulsePlayerStyle.accent)
                    .accessibilityLabel("Exporting…")
                EditorCommand(title: "Cancel export") { departure.request() }
            } else {
                EditorCommand(title: "Preview changes", symbol: .play) {
                    editingRangeName = false
                    scroll.scrollTo("editor-preview", anchor: .top)
                    Task { await editor.applyPreview(audioOnly: output == .audio) }
                }.disabled(!canPlay || editingLocked)
                if savedExport == nil {
                    ActionButton(title: output == .audio ? "Export audio as M4A" : "Export video") {
                        export(audio: output == .audio, title: movie.title)
                    }.disabled(editingLocked)
                }
            }
        }
    }

    private func choose(_ movie: PracticeRecording) {
        openedRequest = nil
        selected = movie
        error = nil
        savedExport = nil
    }

    private func shareExport(_ movie: PracticeRecording) {
        guard !sharingExport, !departure.running else { return }
        guard commerce.canExportMedia else { showingExportMembership = true; return }
        editor.preview.pause()
        error = nil
        sharingExport = true
        shareTask = Task {
            defer { sharingExport = false; shareTask = nil }
            do {
                let url = try await library.shareFile(for: movie, commerce: commerce)
                if !Task.isCancelled { shareURL = SharedFile(url: url) }
            }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }

    private func export(audio: Bool, title: String) {
        guard exportTask == nil, !sharingExport else { return }
        guard let authorization = try? commerce.requireMediaExport() else { showingExportMembership = true; return }
        error = nil
        exportTask = Task {
            defer { exportTask = nil; departure.finish() }
            guard let output = await editor.export(audioOnly: audio) else { return }
            if Task.isCancelled { try? FileManager.default.removeItem(at: output); return }
            do {
                defer { try? FileManager.default.removeItem(at: output) }
                let saved = try await library.saveExport(output, title: title + L10n.text(audio ? " · Audio" : " · Edit"),
                                                         authorization: authorization, commerce: commerce)
                if !Task.isCancelled { savedExport = saved }
            } catch is CancellationError { }
            catch { self.error = "The export finished but could not be added to your library. \(error.localizedDescription)" }
        }
        departure.begin { exportTask?.cancel(); editor.cancelExport() }
    }
}

private struct EditorFullScreenPreview: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var ads: RewardedAds
    @ObservedObject var playback: PlaybackController
    let retry: () -> Void
    @State private var scrubbing = false

    private var canPlay: Bool { scenePhase == .active && !ads.isPresenting }

    var body: some View {
        GeometryReader { container in
            let area = mediaArea(in: container)
            VStack(spacing: 0) {
                VideoSurface(player: playback.player, fill: false)
                    .accessibilityHidden(true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay {
                        if let error = playback.error {
                            ViewThatFits(in: .vertical) {
                                playbackFailure(error)
                                ScrollView { playbackFailure(error) }
                                    .scrollBounceBehavior(.basedOnSize)
                            }
                            .padding(.horizontal, 12).padding(.top, 56)
                            .frame(maxWidth: 420)
                        } else if playback.isLoading && playback.intendsPlayback {
                            ProgressView().tint(PulsePlayerStyle.onDark)
                                .accessibilityLabel(LocalizedStringKey("Loading…"))
                                .allowsHitTesting(false)
                        }
                    }
                transport
            }
            .overlay(alignment: .topTrailing) {
                EditorPreviewModeButton(title: "Exit full screen") { dismiss() }
                    .accessibilityIdentifier("editor.exitFullScreen")
                    .padding(8)
            }
            .frame(width: area.width, height: area.height)
            .padding(.leading, area.minX).padding(.top, area.minY)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .pulsePlayerScreenBackground(PulsePlayerStyle.mediaBackdrop)
        .statusBarHidden(true)
        .preferredColorScheme(.dark)
        .accessibilityAction(.escape) { dismiss() }
    }

    private var transport: some View {
        let playing = playback.intendsPlayback
        return HStack(spacing: 10) {
            Button { playback.toggle() } label: {
                Glyph(symbol: playing ? .pause : .play, size: 20, tint: PulsePlayerStyle.onDark)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel(LocalizedStringKey(playing ? "Pause preview" : "Play preview"))
            .disabled(!canPlay || playback.error != nil || scrubbing)

            PlayerProgressControl(playback: playback, timeline: playback.timeline,
                                  enabled: canPlay, canResume: canPlay, scrubbing: $scrubbing,
                                  tint: PulsePlayerStyle.mediaAccent, showsTimecodes: true, onMedia: true)
        }
        .padding(.horizontal, 8).padding(.top, 6)
        .frame(maxWidth: 540)
        .pulsePlayerGlass(in: RoundedRectangle(cornerRadius: 14), fallback: PulsePlayerStyle.mediaSurface,
                    interactive: false, onDark: true)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func playbackFailure(_ error: String) -> some View {
        MessagePanel(title: "Couldn’t load video", message: error, actionTitle: "Retry") {
            if canPlay { retry() }
        }
        .environment(\.colorScheme, .light)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func mediaArea(in container: GeometryProxy) -> CGRect {
        var area = CGRect(origin: .zero, size: container.size)
        guard #available(iOS 27.1, *) else { return area }
        let regions = container.reservedRegions(kind: .occlusion) + container.reservedRegions(kind: .division)
        for region in regions where region.isActive {
            let intersection = area.intersection(region.frame)
            guard !intersection.isEmpty else { continue }
            let pane = PulsePlayerStyle.largestPane(in: area, excluding: intersection)
            if !pane.isEmpty { area = pane }
        }
        return area
    }
}

private struct EditorPreviewModeButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            LocalizedText(title)
                .font(.capture(.footnote, weight: .semibold))
                .foregroundStyle(PulsePlayerStyle.onDark)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .frame(minWidth: 44, minHeight: 44)
                .pulsePlayerGlass(in: Capsule(), tint: PulsePlayerStyle.mediaBackdrop.opacity(0.72),
                            fallback: PulsePlayerStyle.mediaSurface, onDark: true)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }
}

private struct EditorCommand: View {
    let title: String
    var symbol: PulsePlayerGlyph? = nil
    var emphasized = false
    var expanded = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if expanded {
                ActionLabel(title: title, symbol: symbol, primary: emphasized)
            } else {
                HStack(spacing: 7) {
                    if let symbol { Glyph(symbol: symbol, size: 16, tint: PulsePlayerStyle.accent) }
                    LocalizedText(title).font(.capture(.footnote, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .frame(minWidth: 44, minHeight: 44)
                .foregroundStyle(PulsePlayerStyle.accent)
                .pulsePlayerGlass(in: RoundedRectangle(cornerRadius: 10),
                            tint: emphasized ? PulsePlayerStyle.accent.opacity(0.16) : nil,
                            fallback: emphasized ? PulsePlayerStyle.mist : PulsePlayerStyle.surface)
                .contentShape(Rectangle())
            }
        }.buttonStyle(PressStyle())
    }
}

struct SavedVideoExport: View {
    let movie: PracticeRecording
    let sharing: Bool
    var disabled = false
    let share: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LocalizedText("Saved in Exports").font(.capture(.subheadline, weight: .semibold))
                .foregroundStyle(PulsePlayerStyle.accent)
            Text(verbatim: movie.displayFilename)
                .font(.capture(.footnote)).foregroundStyle(PulsePlayerStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ActionButton(title: "Share or save to Files", primary: false, busy: sharing, action: share)
                .disabled(disabled)
        }
    }
}

private struct VideoOpenRequest: Equatable {
    let movieID: UUID?
    let retryID: UUID
}

private struct ClipRangeLoopButton: View {
    @ObservedObject var playback: PlaybackController
    let range: ClosedRange<Double>
    let start: () -> Void

    var body: some View {
        let looping = playback.repeatedRange == range
        EditorCommand(title: looping ? "Stop loop" : "Loop range", symbol: looping ? .pause : .play) {
            if looping {
                playback.pause()
                playback.stopRepeating()
            } else { start() }
        }
    }
}

private struct VideoRangePanel: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.locale) private var locale
    @ObservedObject var playback: PlaybackController
    let movieID: UUID
    let duration: Double
    let start: Double
    let end: Double
    let saveAndLoop: Bool
    let activeLoopID: UUID?
    @Binding var name: String
    let editingName: FocusState<Bool>.Binding
    let compareRange: (VideoRangeMark) -> Void
    let playRange: (VideoRangeMark) -> Void
    let trimToRange: (ClosedRange<Double>) -> Void
    @State private var error: String?

    var body: some View {
        let movie = library.movies.first { $0.id == movieID }
        let marks = (movie?.rangeMarks ?? []).filter { ($0.timeRange?.upperBound ?? .infinity) <= duration }
        return VStack(alignment: .leading, spacing: 12) {
            if marks.isEmpty && !saveAndLoop {
                LocalizedText("Mark a range to loop it and compare frames.")
                    .font(.capture(.footnote)).foregroundStyle(PulsePlayerStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            makeRange
            if let error { ErrorNote(message: error) }
            if let movie, !marks.isEmpty {
                LocalizedText("Saved ranges").font(.capture(.headline))
                    .accessibilityAddTraits(.isHeader)
                    .id("editor-saved-ranges")
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(marks) { mark in
                        if let range = mark.timeRange {
                            rangeRow(mark, range: range, url: library.url(for: movie))
                        }
                    }
                }
            }
        }
    }

    private var makeRange: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !saveAndLoop {
                LocalizedText("Trim").font(.capture(.caption, weight: .semibold))
                    .foregroundStyle(PulsePlayerStyle.secondary)
                timeRange(start: start, end: end)
                    .font(.capture(.subheadline, weight: .semibold)).foregroundStyle(PulsePlayerStyle.paper)
            }
            TextField("Range name (optional)", text: $name,
                      prompt: Text("Range name (optional)").foregroundStyle(PulsePlayerStyle.secondary))
                .font(.capture(.subheadline)).pulsePlayerField()
                .focused(editingName).submitLabel(.done)
                .onSubmit { saveRange() }
                .keyboardInputRegion("editor-range-name")
                .accessibilityIdentifier("video.range.name")
            EditorCommand(title: saveAndLoop ? "Save and loop" : "Save range",
                          symbol: saveAndLoop ? .play : .bookmark, emphasized: true, expanded: saveAndLoop,
                          action: saveRange)
                .accessibilityIdentifier("video.range.save")
        }
        .padding(12).pulsePlayerPanel(cornerRadius: 14)
    }

    private func rangeRow(_ mark: VideoRangeMark, range: ClosedRange<Double>, url: URL) -> some View {
        let isLooping = activeLoopID == mark.id && playback.repeatedRange == range
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                VideoFileThumbnail(url: url, timestamp: mark.start)
                    .frame(width: 76, height: 50).clipShape(.rect(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: mark.name.nilIfBlank ?? L10n.text("Unnamed range", language: AppLanguage.from(locale)))
                        .font(.capture(.subheadline, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    timeRange(start: mark.start, end: mark.end)
                        .font(.capture(.footnote, weight: .semibold))
                        .foregroundStyle(isLooping ? PulsePlayerStyle.accent : PulsePlayerStyle.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                IconButton(symbol: .close, label: "Remove range") {
                    error = nil
                    do {
                        try library.removeRange(mark, from: movieID)
                        if isLooping {
                            playback.pause()
                            playback.stopRepeating()
                        }
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            }
            PulsePlayerGlassGroup {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) { rangeActions(mark, range: range, isLooping: isLooping) }
                        .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 4) { rangeActions(mark, range: range, isLooping: isLooping) }
                }
            }
        }
        .padding(10)
        .background(PulsePlayerStyle.accent.opacity(isLooping ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .bottom) {
            Rectangle().fill(isLooping ? PulsePlayerStyle.accent : PulsePlayerStyle.line)
                .frame(height: 1).allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    @ViewBuilder private func rangeActions(_ mark: VideoRangeMark, range: ClosedRange<Double>, isLooping: Bool) -> some View {
        EditorCommand(title: isLooping ? "Stop loop" : "Loop range", symbol: isLooping ? .pause : .play, emphasized: true) {
            editingName.wrappedValue = false
            if isLooping {
                playback.pause()
                playback.stopRepeating()
            } else {
                playRange(mark)
            }
        }
        EditorCommand(title: "Compare 3 frames", symbol: .feed) {
            compareRange(mark)
        }.accessibilityIdentifier("video.range.compareFrames")
        EditorCommand(title: "Use for trim", symbol: .edit) {
            editingName.wrappedValue = false
            trimToRange(range)
        }
    }

    private func timeRange(start: Double, end: Double) -> some View {
        Text(verbatim: "\(durationLabel(start, fractional: true)) – \(durationLabel(end, fractional: true))")
            .monospacedDigit().environment(\.layoutDirection, .leftToRight)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func saveRange() {
        guard start.isFinite, end.isFinite, start >= 0, end - start >= 1.0 / 600, end <= duration else {
            error = "Choose a start and end for the range."
            return
        }
        editingName.wrappedValue = false
        do {
            let mark = try library.addRange(start...end, name: name, to: movieID)
            name = ""
            error = nil
            if saveAndLoop { playRange(mark) }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct RangeFrameRequest: Identifiable {
    let source: URL
    let mark: VideoRangeMark
    var id: UUID { mark.id }

    func title(in language: AppLanguage) -> String {
        mark.name.nilIfBlank ?? L10n.text("Unnamed range", language: language)
    }

    @MainActor
    func readFrames(maximumSize: CGFloat = 1440) async throws -> [RangeStill] {
        guard source.isFileURL, FileManager.default.isReadableFile(atPath: source.path) else {
            throw PulsePlayerError.service("This file can’t be read. Choose the video again from Files.")
        }
        guard let range = mark.timeRange else { throw PulsePlayerError.service("Choose a start and end for the range.") }
        let asset = AVURLAsset(url: source)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maximumSize, height: maximumSize)
        let tolerance = CMTime(value: 1, timescale: 8)
        generator.requestedTimeToleranceBefore = tolerance
        let length = range.upperBound - range.lowerBound
        // At the end of the asset, sample just before the last boundary.
        let samples: [(RangeStill.Position, Double)] = [
            (.start, range.lowerBound),
            (.middle, range.lowerBound + length / 2),
            (.end, range.upperBound - min(length / 8, 1.0 / 60))
        ]
        do {
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, range.upperBound <= duration else {
                throw PulsePlayerError.service("This range no longer fits the video.")
            }
            var frames: [RangeStill] = []
            for (position, time) in samples {
                try Task.checkCancellation()
                generator.requestedTimeToleranceAfter = position == .end ? .zero : tolerance
                let result = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 60_000))
                let actual = result.actualTime.seconds
                frames.append(RangeStill(position: position, image: result.image, time: actual.isFinite ? actual : time))
            }
            try Task.checkCancellation()
            return frames
        } catch let error as PulsePlayerError {
            throw error
        } catch {
            try Task.checkCancellation()
            throw PulsePlayerError.service("Couldn’t read these frames. Try again.")
        }
    }
}

struct RangeStill: Identifiable, Sendable {
    enum Position: String, Sendable {
        case start, middle, end

        var title: String {
            switch self {
            case .start: "Start"
            case .middle: "Middle"
            case .end: "End"
            }
        }
    }

    let position: Position
    let image: CGImage
    let time: Double
    var id: Position { position }
}

private struct SharedRangeStills: Identifiable, Sendable {
    let folder: URL
    let files: [URL]
    var id: URL { folder }
}

@MainActor
private struct RangeFrameComparison: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var typeSize
    let request: RangeFrameRequest
    @State private var frames: [RangeStill] = []
    @State private var selectedPosition: RangeStill.Position = .start
    @State private var overlayEnds = false
    @State private var endOpacity = 50.0
    @State private var loadAttempt = UUID()
    @State private var loadError: String?
    @State private var exporting = false

    var body: some View {
        VStack(spacing: 0) {
            SheetHeading(title: "Compare 3 frames") { dismiss() }.disabled(exporting)
            ScenePage { container in
                VStack(alignment: .leading, spacing: 16) {
                    Text(verbatim: request.title(in: AppLanguage.from(locale)))
                        .font(.capture(.title3, display: true))
                        .fixedSize(horizontal: false, vertical: true)
                    if let selected = frames.first(where: { $0.position == selectedPosition }) {
                        if overlayEnds, let first = frames.first, let last = frames.last {
                            ZStack {
                                Image(decorative: first.image, scale: 1).resizable().scaledToFit()
                                Image(decorative: last.image, scale: 1).resizable().scaledToFit()
                                    .opacity(endOpacity / 100)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: min(350, max(130, container.size.height * 0.4)))
                            .background(PulsePlayerStyle.mediaBackdrop)
                            LocalizedText("Slide from the first frame to the last to check the edges.")
                                .foregroundStyle(PulsePlayerStyle.secondary)
                            PulsePlayerScrubber(value: $endOpacity, range: 0...100, label: "Last frame opacity", showsThumb: true)
                                .accessibilityValue((endOpacity / 100).formatted(.percent.locale(locale)))
                        } else {
                            preview(selected, in: container)
                            frameStrip(in: container)
                        }
                        ActionButton(title: overlayEnds ? "Show individual frames" : "Overlay first and last frames", primary: false) {
                            overlayEnds.toggle()
                        }
                        RangeShareActions(request: request, frames: frames, busy: $exporting)
                    } else if let loadError {
                        ErrorNote(message: loadError)
                        ActionButton(title: "Retry", primary: false) { loadAttempt = UUID() }
                    } else {
                        AccountLoadingIndicator(title: "Reading video frames…")
                    }
                }
            }
        }.pulsePlayerScreenBackground().foregroundStyle(PulsePlayerStyle.paper)
            .interactiveDismissDisabled(exporting)
            .task(id: loadAttempt) { await loadFrames() }
    }

    private func preview(_ frame: RangeStill, in container: GeometryProxy) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(decorative: frame.image, scale: 1).resizable().scaledToFit()
                .frame(maxWidth: .infinity)
                .frame(height: min(350, max(130, container.size.height * 0.4)))
                .background(PulsePlayerStyle.mediaBackdrop)
            frameCaption(frame)
        }
    }

    private func frameStrip(in container: GeometryProxy) -> some View {
        let bounds = CGRect(origin: .zero, size: container.size)
        let wide = typeSize <= .xLarge && PulsePlayerStyle.pageContentWidth(in: container) >= 300
            && !PulsePlayerStyle.intersectsReservedRegion(bounds, in: container)
        let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 8))
                          : AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
        return layout {
            ForEach(frames) { frame in
                let selected = frame.position == selectedPosition
                Button { selectedPosition = frame.position } label: {
                    let cell = wide ? AnyLayout(VStackLayout(alignment: .leading, spacing: 7))
                                    : AnyLayout(HStackLayout(spacing: 12))
                    cell {
                        Image(decorative: frame.image, scale: 1).resizable().scaledToFit()
                            .frame(width: wide ? nil : 70, height: 54)
                            .frame(maxWidth: wide ? .infinity : nil)
                            .background(PulsePlayerStyle.mediaBackdrop)
                            .accessibilityHidden(true)
                        frameCaption(frame)
                    }.padding(7).frame(maxWidth: .infinity, alignment: .leading)
                        .background(selected ? PulsePlayerStyle.accent.opacity(0.12) : PulsePlayerStyle.surface,
                                    in: RoundedRectangle(cornerRadius: 9))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? PulsePlayerStyle.accent : PulsePlayerStyle.line)
                                .allowsHitTesting(false)
                        }
                        .contentShape(Rectangle())
                }.buttonStyle(PressStyle())
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private func frameCaption(_ frame: RangeStill) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LocalizedText(frame.position.title).font(.capture(.subheadline, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: durationLabel(frame.time, fractional: true)).font(.capture(.caption))
                .monospacedDigit().foregroundStyle(PulsePlayerStyle.secondary)
                .environment(\.layoutDirection, .leftToRight)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loadFrames() async {
        loadError = nil
        do {
            frames = try await request.readFrames()
        } catch {
            if !Task.isCancelled { loadError = error.localizedDescription }
        }
    }
}

@MainActor
private struct RangeShareActions: View {
    private enum Format { case comparison, stills }

    @EnvironmentObject private var commerce: CommerceStore
    @Environment(\.locale) private var locale
    let request: RangeFrameRequest
    let frames: [RangeStill]
    @Binding var busy: Bool
    @State private var exportTask: Task<Void, Never>?
    @State private var exportError: String?
    @State private var showingPlus = false
    @State private var sharedStills: SharedRangeStills?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            comparisonActions(request, frames: frames).disabled(busy)
            exportNote
            if busy { AccountLoadingIndicator(title: "Preparing export…") }
            if let exportError { ErrorNote(message: exportError) }
        }
        .fullScreenCover(isPresented: $showingPlus) { MembershipView(entry: .frameComparison) }
        .sheet(item: $sharedStills) { ShareSheet(items: $0.files) }
        .onDisappear { exportTask?.cancel() }
    }

    @ViewBuilder private var exportNote: some View {
        if !commerce.hasVerifiedPlus {
            LocalizedText("Export is included with Plus.").font(.capture(.footnote))
                .foregroundStyle(PulsePlayerStyle.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func comparisonActions(_ request: RangeFrameRequest, frames: [RangeStill]) -> some View {
        let collage = EditorCommand(title: "Share three-frame collage", symbol: .download,
                                    emphasized: true, expanded: true) {
            export(request, frames: frames, format: .comparison)
        }.accessibilityIdentifier("video.range.shareComparison")
        let stills = EditorCommand(title: "Export JPEG stills", symbol: .feed) {
            export(request, frames: frames, format: .stills)
        }.accessibilityIdentifier("video.range.exportStills")
        return PulsePlayerGlassGroup {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    collage.fixedSize(horizontal: true, vertical: false)
                    stills.fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: 4) {
                    collage
                    stills
                }
            }
        }
    }

    private func export(_ request: RangeFrameRequest, frames: [RangeStill], format: Format) {
        guard !busy, exportTask == nil else { return }
        exportError = nil
        guard let authorization = try? commerce.requireMediaExport() else { showingPlus = true; return }
        busy = true
        let language = AppLanguage.from(locale)
        exportTask = Task {
            defer { exportTask = nil; busy = false }
            var staged: SharedRangeStills?
            do {
                try commerce.requireMediaExport(authorization)
                try Task.checkCancellation()
                let images = try imagesToShare(frames, request: request, language: language, format: format)
                let credit = CraneChapter.filmCredit(for: request.source)
                let writer = Task.detached(priority: .userInitiated) { try Self.stageJPEGs(images, credit: credit) }
                let result = try await withTaskCancellationHandler {
                    try await writer.value
                } onCancel: { writer.cancel() }
                staged = result
                try Task.checkCancellation()
                try commerce.requireMediaExport(authorization)
                sharedStills = result
            } catch {
                if let staged { try? FileManager.default.removeItem(at: staged.folder) }
                if !Task.isCancelled { exportError = error.localizedDescription }
            }
        }
    }

    private func imagesToShare(_ frames: [RangeStill], request: RangeFrameRequest, language: AppLanguage,
                               format: Format) throws -> [(name: String, image: CGImage)] {
        switch format {
        case .stills:
            return frames.enumerated().map { index, frame in
                ("\(index + 1)-\(frame.position.rawValue).jpg", frame.image)
            }
        case .comparison:
            let comparison = RangeComparisonImage(title: request.title(in: language), frames: frames, language: language)
            let renderer = ImageRenderer(content: comparison)
            renderer.scale = 2
            renderer.isOpaque = true
            guard let image = renderer.cgImage else { throw PulsePlayerError.service("Couldn’t create the comparison image. Try again.") }
            return [("PulsePlayer-range-\(request.id.uuidString.prefix(8)).jpg", image)]
        }
    }

    nonisolated private static func stageJPEGs(_ images: [(name: String, image: CGImage)], credit: String?) throws -> SharedRangeStills {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("PulsePlayerRangeStills", isDirectory: true)
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let expiry = Date().addingTimeInterval(-7 * 86_400)
        for old in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
            if let created = try? old.resourceValues(forKeys: [.creationDateKey]).creationDate, created < expiry {
                try? fm.removeItem(at: old)
            }
        }
        do {
            var options: [String: Any] = [kCGImageDestinationLossyCompressionQuality as String: 0.92]
            if let credit {
                options[kCGImagePropertyTIFFDictionary as String] = [kCGImagePropertyTIFFImageDescription as String: credit]
            }
            var files: [URL] = []
            for image in images {
                try Task.checkCancellation()
                let file = folder.appendingPathComponent(image.name)
                guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                    throw PulsePlayerError.service("Couldn’t export the JPEGs. Try again.")
                }
                CGImageDestinationAddImage(destination, image.image, options as CFDictionary)
                guard CGImageDestinationFinalize(destination) else {
                    throw PulsePlayerError.service("Couldn’t export the JPEGs. Try again.")
                }
                files.append(file)
            }
            try Task.checkCancellation()
            return SharedRangeStills(folder: folder, files: files)
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
    }
}

private struct RangeComparisonImage: View {
    let title: String
    let frames: [RangeStill]
    let language: AppLanguage
    private let imageWidth: CGFloat = 256
    // The exported comparison keeps its own palette independent of the editor chrome.
    private let canvas = Color(red: 16.0 / 255, green: 28.0 / 255, blue: 41.0 / 255)
    private let letterbox = Color(red: 15.0 / 255, green: 33.0 / 255, blue: 43.0 / 255)
    private let foreground = Color(red: 239.0 / 255, green: 247.0 / 255, blue: 252.0 / 255)
    private let captionAccent = Color(red: 143.0 / 255, green: 228.0 / 255, blue: 212.0 / 255)

    var body: some View {
        let height = frames.first.map { imageWidth * CGFloat($0.image.height) / CGFloat($0.image.width) } ?? 144
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: title).font(.system(size: 28, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .top, spacing: 12) {
                ForEach(frames) { frame in
                    VStack(alignment: .leading, spacing: 8) {
                        Image(decorative: frame.image, scale: 1).resizable().scaledToFit()
                            .frame(width: imageWidth, height: min(440, max(132, height)))
                            .background(letterbox)
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(verbatim: L10n.text(frame.position.title, language: language))
                                .font(.system(size: 16, weight: .semibold)).foregroundStyle(captionAccent)
                            Spacer(minLength: 0)
                            Text(verbatim: durationLabel(frame.time, fractional: true))
                                .font(.system(size: 16, weight: .medium, design: .monospaced))
                                .environment(\.layoutDirection, .leftToRight)
                        }.environment(\.layoutDirection, language.direction)
                    }.frame(width: imageWidth)
                }
            }.environment(\.layoutDirection, .leftToRight)
        }.padding(24).frame(width: imageWidth * 3 + 72)
            .foregroundStyle(foreground).background(canvas)
            .environment(\.layoutDirection, language.direction)
    }
}

private struct VideoPlaybackControls: View {
    @ObservedObject var playback: PlaybackController
    @ObservedObject var timeline: PlaybackTimeline
    let enabled: Bool
    let canResume: Bool
    @Binding var scrubbing: Bool
    let retry: () -> Void
    let sourceFrames: [UIImage?]?
    let sourceDuration: Double
    let trim: ClosedRange<Double>
    let compareLoop: (() -> Void)?
    let rangesTitle: String
    let openRanges: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            PulsePlayerGlassGroup {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) {
                        playbackStatus.fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 0)
                        reviewCommands.fixedSize(horizontal: true, vertical: false)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        playbackStatus
                        reviewCommands
                    }
                }
            }
            PlayerProgressControl(playback: playback, timeline: timeline, enabled: enabled,
                                  canResume: canResume, scrubbing: $scrubbing,
                                  tint: sourceFrames == nil ? PulsePlayerStyle.accent : PulsePlayerStyle.mediaAccent,
                                  showsPlayhead: sourceFrames != nil)
                .background {
                    if let sourceFrames {
                        EditorFilmstrip(frames: sourceFrames, duration: sourceDuration,
                                        trim: trim, looping: playback.repeatedRange)
                    }
                }
            if let error = playback.error {
                ErrorNote(message: "Preview could not play. \(error)")
                EditorCommand(title: "Retry", action: retry).disabled(!enabled)
            }
        }
        .padding(12)
        .pulsePlayerPanel(cornerRadius: 14)
    }

    private var playbackStatus: some View {
        let playing = playback.intendsPlayback
        let mode = playback.repeatedRange != nil ? "Looping" : sourceFrames == nil ? "Edited preview" : "Original"
        let duration = timeline.duration > 0 || sourceFrames == nil ? timeline.duration : sourceDuration
        let elapsed = durationLabel(timeline.elapsed, fractional: true)
        let total = Text(verbatim: durationLabel(duration, fractional: true))
            .foregroundStyle(PulsePlayerStyle.secondary)
        return HStack(spacing: 9) {
            IconButton(symbol: playing ? .pause : .play, label: playing ? "Pause preview" : "Play preview", glass: true) {
                playback.toggle()
            }
            .disabled(!enabled || playback.error != nil)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(elapsed) / \(total)")
                    .font(.capture(.subheadline, weight: .semibold)).monospacedDigit()
                    .environment(\.layoutDirection, .leftToRight)
                LocalizedText(mode).font(.capture(.caption))
                    .foregroundStyle(playback.repeatedRange != nil ? PulsePlayerStyle.accent : PulsePlayerStyle.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            if playback.isLoading && playing {
                ProgressView().tint(PulsePlayerStyle.accent).accessibilityLabel("Loading…")
            }
        }
    }

    @ViewBuilder private var reviewCommands: some View {
        if playback.repeatedRange != nil {
            EditorCommand(title: "Stop loop", symbol: .pause) {
                playback.pause()
                playback.stopRepeating()
            }.disabled(!enabled)
        }
        if playback.repeatedRange != nil, let compareLoop {
            EditorCommand(title: "Compare 3 frames", symbol: .feed, action: compareLoop)
                .disabled(!enabled)
                .accessibilityIdentifier("editor.compareLoop")
        } else if let openRanges {
            EditorCommand(title: rangesTitle, symbol: .bookmark, action: openRanges)
                .disabled(!enabled)
                .accessibilityIdentifier("editor.openRanges")
        }
    }
}

private struct EditorFilmstrip: View {
    let frames: [UIImage?]
    let duration: Double
    let trim: ClosedRange<Double>
    let looping: ClosedRange<Double>?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let cellWidth = width / CGFloat(max(1, frames.count))
            let start = offset(for: trim.lowerBound, width: width)
            let end = offset(for: trim.upperBound, width: width)
            ZStack(alignment: .leading) {
                PulsePlayerStyle.mediaSurface
                HStack(spacing: 0) {
                    ForEach(frames.indices, id: \.self) { index in
                        Group {
                            if let frame = frames[index] {
                                Image(uiImage: frame).resizable().scaledToFill()
                            } else {
                                PulsePlayerStyle.mediaBackdrop
                            }
                        }
                        .frame(width: cellWidth, height: height)
                        .clipped()
                        .overlay(alignment: .trailing) {
                            Rectangle().fill(PulsePlayerStyle.mediaBackdrop.opacity(0.65)).frame(width: 1)
                        }
                    }
                }
                Color.black.opacity(0.58).frame(width: start)
                Color.black.opacity(0.58).frame(width: width - end).offset(x: end)
                RoundedRectangle(cornerRadius: 6).strokeBorder(PulsePlayerStyle.mediaAccent, lineWidth: 1)
                    .frame(width: max(0, end - start)).offset(x: start)
                if let looping {
                    let loopStart = offset(for: looping.lowerBound, width: width)
                    let loopEnd = offset(for: looping.upperBound, width: width)
                    Capsule().fill(PulsePlayerStyle.mediaAccent)
                        .frame(width: max(0, loopEnd - loopStart), height: 4)
                        .padding(.bottom, 3)
                        .frame(height: height, alignment: .bottom)
                        .offset(x: loopStart)
                }
            }
        }
        .clipShape(.rect(cornerRadius: 6))
        .environment(\.layoutDirection, .leftToRight)
        .allowsHitTesting(false).accessibilityHidden(true)
    }

    private func offset(for time: Double, width: CGFloat) -> CGFloat {
        width * CGFloat(min(1, max(0, time / duration)))
    }
}

struct VideoImportActions: View {
    enum Presentation: Equatable {
        case standard, prominent
        case library(stacked: Bool, photosFirst: Bool = false)
        case sourcePair(stacked: Bool)
    }

    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dynamicTypeSize) private var typeSize
    let onImported: (PracticeRecording) -> Void
    @Binding var importing: Bool
    var presentation: Presentation = .standard
    var folderID: UUID? = nil
    @State private var photo: PhotosPickerItem?
    @State private var showingFiles = false
    @State private var error: String?

    private var prominent: Bool { presentation == .prominent }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if importing {
                HStack(spacing: 10) {
                    ProgressView().tint(PulsePlayerStyle.accent).accessibilityHidden(true)
                    LocalizedText("Importing…").font(.capture(.subheadline, weight: .semibold))
                }.frame(minHeight: 48)
            } else if case let .sourcePair(stacked) = presentation {
                sourceStrip(stacked: stacked || typeSize > .xLarge)
            } else if case let .library(stacked, photosFirst) = presentation {
                sourceStrip(stacked: stacked || typeSize > .xLarge,
                            photosFirst: photosFirst, compact: !photosFirst)
            } else {
                let paired = prominent && !typeSize.isAccessibilitySize
                let layout = paired ? AnyLayout(HStackLayout(spacing: 8))
                                    : AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                PulsePlayerGlassGroup {
                    layout {
                        fileButton
                        PhotosPicker(selection: $photo, matching: .videos, photoLibrary: .shared()) {
                            photosLabel
                                .frame(minHeight: prominent ? 78 : 48)
                                .pulsePlayerGlass(in: RoundedRectangle(cornerRadius: 14))
                        }.buttonStyle(PressStyle())
                            .fixedSize(horizontal: paired, vertical: false)
                            .accessibilityIdentifier("video.import.photos")
                    }
                }
            }
            if let error { ErrorNote(message: error) }
        }
        .fileImporter(isPresented: $showingFiles, allowedContentTypes: [.movie]) { result in
            do {
                let url = try result.get()
                importVideo { try await library.importMovie(url, folderID: folderID) }
            } catch { showImportError(error) }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            importVideo {
                guard let media = try await item.loadTransferable(type: ImportedMovie.self) else {
                    throw PulsePlayerError.unsupportedMedia
                }
                defer { try? FileManager.default.removeItem(at: media.url) }
                return try await library.importMovie(media.url, title: media.suggestedTitle ?? L10n.text("Imported video"),
                                                     folderID: folderID)
            }
        }
    }

    private func sourceStrip(stacked: Bool, photosFirst: Bool = false, compact: Bool = false) -> some View {
        let layout = stacked ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))
        let divider = Rectangle().fill(PulsePlayerStyle.line)
            .frame(width: stacked ? nil : 1, height: stacked ? 1 : 24)
            .accessibilityHidden(true)
        let files = Button { showingFiles = true } label: {
            sourceLabel("Files", glyph: .folder, primary: !photosFirst, stacked: stacked, compact: compact)
        }
        .buttonStyle(PressStyle())
        .fixedSize(horizontal: !stacked && photosFirst, vertical: false)
        .accessibilityLabel("Open video file")
        .accessibilityIdentifier("video.import.files")

        let photos = PhotosPicker(selection: $photo, matching: .videos, photoLibrary: .shared()) {
            sourceLabel(photosFirst ? "Choose from Photos" : "Photos", glyph: .feed,
                        primary: photosFirst, stacked: stacked, compact: compact)
        }
        .buttonStyle(PressStyle())
        .fixedSize(horizontal: !stacked && !photosFirst, vertical: false)
        .accessibilityLabel("Choose from Photos")
        .accessibilityIdentifier("video.import.photos")

        return layout {
            if photosFirst {
                photos
                divider
                files
            } else {
                files
                divider
                photos
            }
        }
        .padding(compact ? 2 : 4)
        .pulsePlayerGlass(in: RoundedRectangle(cornerRadius: 14), interactive: false)
    }

    private func sourceLabel(_ title: String, glyph: PulsePlayerGlyph, primary: Bool, stacked: Bool, compact: Bool) -> some View {
        HStack(spacing: 8) {
            LocalizedText(title).font(.capture(compact ? .footnote : .subheadline, weight: primary ? .semibold : .medium))
                .fixedSize(horizontal: false, vertical: true)
            if primary || stacked { Spacer(minLength: 4) }
            Glyph(symbol: glyph, size: compact ? 15 : 19, tint: primary ? PulsePlayerStyle.accent : PulsePlayerStyle.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, compact ? 4 : 8)
        .frame(minWidth: 44, minHeight: compact ? 36 : 46, alignment: .leading)
        .foregroundStyle(PulsePlayerStyle.paper)
        .background(primary ? PulsePlayerStyle.accent.opacity(0.105) : .clear,
                    in: RoundedRectangle(cornerRadius: compact ? 10 : 14, style: .continuous))
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private var fileButton: some View {
        Button { showingFiles = true } label: {
            HStack(spacing: 12) {
                Glyph(symbol: .folder, size: prominent ? 24 : 18, tint: PulsePlayerStyle.ink)
                    .frame(width: prominent ? 48 : 34, height: prominent ? 48 : 34)
                    .background(PulsePlayerStyle.accent, in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 3) {
                    LocalizedText(prominent ? "Open video" : "Open video file")
                        .font(.capture(prominent ? .title2 : .subheadline, weight: .semibold, display: prominent))
                    if prominent { LocalizedText("Files").font(.capture(.caption)).foregroundStyle(PulsePlayerStyle.secondary) }
                }.fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .frame(minHeight: prominent ? 78 : 48)
            .foregroundStyle(PulsePlayerStyle.paper)
            .pulsePlayerGlass(in: RoundedRectangle(cornerRadius: 16), tint: PulsePlayerStyle.accent.opacity(0.10))
            .contentShape(Rectangle())
        }.buttonStyle(PressStyle())
            .accessibilityLabel("Open video file")
            .accessibilityIdentifier("video.import.files")
    }

    private var photosLabel: some View {
        let stacked = prominent && !typeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(spacing: 5)) : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            Glyph(symbol: .feed, size: stacked ? 23 : 18, tint: PulsePlayerStyle.accent)
            LocalizedText(prominent ? "Photos" : "Choose from Photos")
                .font(.capture(stacked ? .footnote : .subheadline, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: stacked ? nil : .infinity, alignment: .leading)
        }.padding(.horizontal, 14).padding(.vertical, 8)
            .frame(minWidth: stacked ? 80 : 44)
            .foregroundStyle(PulsePlayerStyle.paper)
            .contentShape(Rectangle())
    }

    private func importVideo(_ operation: @escaping () async throws -> PracticeRecording) {
        guard !importing else { return }
        importing = true
        error = nil
        Task {
            defer {
                photo = nil
                importing = false
            }
            do {
                let movie = try await operation()
                onImported(movie)
            } catch { showImportError(error) }
        }
    }

    private func showImportError(_ error: Error) {
        let failure = error as NSError
        guard !(error is CancellationError),
              !(failure.domain == NSCocoaErrorDomain && failure.code == NSUserCancelledError),
              !(failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled) else { return }
        if failure.domain == NSCocoaErrorDomain,
           [NSFileNoSuchFileError, NSFileReadNoSuchFileError, NSFileReadNoPermissionError].contains(failure.code) {
            self.error = "This file can’t be read. Choose the video again from Files."
        } else {
            self.error = error.localizedDescription
        }
    }
}

struct VideoFileButton: View {
    enum Presentation: Equatable {
        case row, featured, thumbnail
        case picker(tiled: Bool)
    }

    @Environment(\.dynamicTypeSize) private var typeSize
    let url: URL
    let filename: String
    let date: Date
    var presentation: Presentation = .row
    var fallbackCover: URL? = nil
    var detail: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if case let .picker(tiled) = presentation {
                pickerLabel(tiled: tiled)
            } else if presentation == .thumbnail {
                coverLabel(featured: false)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .pulsePlayerPanel(cornerRadius: 16)
                    .contentShape(.interaction, RoundedRectangle(cornerRadius: 16))
            } else if presentation == .featured && !typeSize.isAccessibilitySize {
                coverLabel(featured: true)
                    .contentShape(Rectangle())
            } else {
                HStack(spacing: 12) {
                    VideoFileThumbnail(url: url, fallbackCover: fallbackCover)
                        .frame(width: 64, height: 42)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    fileLabel
                }
                .padding(.vertical, 5)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(PressStyle())
    }

    private func pickerLabel(tiled: Bool) -> some View {
        let layout = tiled ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                           : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            VideoFileThumbnail(url: url, maximumSize: tiled ? 720 : 360, fallbackCover: fallbackCover)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(width: tiled ? nil : 104)
                .clipShape(.rect(cornerRadius: 8))
            fileLabel
        }
        .padding(.vertical, tiled ? 0 : 6)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func coverLabel(featured: Bool) -> some View {
        VStack(alignment: .leading, spacing: featured ? 10 : 0) {
            VideoFileThumbnail(url: url, maximumSize: featured ? 1080 : 640, fallbackCover: fallbackCover)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay(alignment: .bottomTrailing) {
                    let size: CGFloat = featured ? 48 : 34
                    Glyph(symbol: .play, size: featured ? 21 : 15, tint: PulsePlayerStyle.onDark)
                        .frame(width: size, height: size)
                        .pulsePlayerGlass(in: Circle(), fallback: PulsePlayerStyle.mediaBackdrop, interactive: false, onDark: true)
                        .padding(featured ? 10 : 8)
                        .allowsHitTesting(false)
                }
            fileLabel
                .padding(.horizontal, featured ? 0 : 12)
                .padding(.vertical, featured ? 3 : 10)
        }
    }

    private var fileLabel: some View {
        let name = Text(verbatim: filename).font(.capture(.subheadline, weight: .semibold))
            .foregroundStyle(PulsePlayerStyle.paper)
        let opened = LocalizedDateText(date: date)
            .font(.capture(.caption)).foregroundStyle(PulsePlayerStyle.secondary)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                if presentation == .thumbnail || presentation == .picker(tiled: true) {
                    name.lineLimit(2, reservesSpace: true).truncationMode(.middle)
                    opened.lineLimit(typeSize.isAccessibilitySize ? 2 : 1, reservesSpace: true)
                } else {
                    name.fixedSize(horizontal: false, vertical: true)
                    opened
                }
                if let detail {
                    LocalizedText(detail).font(.capture(.caption)).foregroundStyle(PulsePlayerStyle.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if presentation != .thumbnail {
                Glyph(symbol: .back, size: 13, tint: PulsePlayerStyle.secondary).rotationEffect(.degrees(180))
            }
        }
    }
}

struct VideoFileThumbnail: View {
    let url: URL
    var maximumSize: CGFloat = 216
    var isAudio = false
    var fallbackCover: URL? = nil
    var timestamp: Double = 0
    var contentMode: ContentMode = .fill
    @State private var frame: CGImage?
    @State private var needsCover = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                contentMode == .fit ? PulsePlayerStyle.mediaBackdrop : PulsePlayerStyle.raised
                if let frame {
                    Image(decorative: frame, scale: 1).resizable().aspectRatio(contentMode: contentMode)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else if needsCover, let fallbackCover {
                    MediaCover(url: fallbackCover)
                } else {
                    Glyph(symbol: isAudio ? .sound : .feed,
                          size: 22, tint: contentMode == .fit ? PulsePlayerStyle.mediaSecondary : PulsePlayerStyle.secondary)
                }
            }
            .clipped()
        }
        .accessibilityHidden(true)
        .task(id: url) {
            frame = nil
            needsCover = false
            guard !isAudio else { return }
            guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path) else { needsCover = true; return }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maximumSize, height: maximumSize)
            if timestamp > 0 {
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
            }
            let time = CMTime(seconds: timestamp, preferredTimescale: 600)
            let result = try? await generator.image(at: time)
            guard !Task.isCancelled else { return }
            frame = result?.image
            needsCover = frame == nil
        }
    }
}

struct FlowChoices: View {
    let values: [String]
    let selected: String
    var action: (String) -> Void
    var body: some View {
        ChoiceStrip(values: values, selected: selected, select: action)
    }
}
struct SharedFile: Identifiable { let id = UUID(); let url: URL }
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
