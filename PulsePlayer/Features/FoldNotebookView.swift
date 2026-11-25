import SwiftUI
import UniformTypeIdentifiers

struct FoldNotebookView: View {
    let lessonFirst: Bool

    init(lessonFirst: Bool = false) {
        self.lessonFirst = lessonFirst
    }
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var offline: OfflineStore
    @ObservedObject private var practice = FoldPracticeStore.shared
    @State private var player: PlayerRoute?
    @State private var error: String?
    @State private var export: FoldTimesCSV?
    @State private var exporting = false
    @State private var clipEntry: FoldPracticeEntry?

    var body: some View {
        let entries = practice.recent(owner: api.offlineOwnerID, library: library, offline: offline)
        VStack(spacing: 0) {
            SheetHeading(title: "Practice notebook") { dismiss() }
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if lessonFirst { lesson }
                    if !entries.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            SceneTitle("Your folds", size: 28)
                            ForEach(entries) { entry in
                                session(entry)
                                Divider()
                            }
                        }
                    }
                    if !lessonFirst { lesson }
                    if let error {
                        LocalizedText(error).font(.callout).foregroundStyle(PulsePlayerStyle.danger)
                    }
                }.pulsePlayerPage()
            }
        }
        .foregroundStyle(PulsePlayerStyle.paper)
        .pulsePlayerScreenBackground()
        .fullScreenCover(item: $player) { PlayerScreen(route: $0) }
        .sheet(item: $clipEntry) { FoldClipExportView(entry: $0) }
        .fileExporter(isPresented: $exporting, document: export, contentType: .commaSeparatedText,
                      defaultFilename: "PulsePlayer-fold-times") { result in
            if case .failure(let problem) = result { error = problem.localizedDescription }
        }
    }

    private var lesson: some View {
        VStack(alignment: .leading, spacing: 14) {
            SceneTitle("Fold a paper crane", size: 34)
            Image("PaperCranePreview.jpg")
                .resizable().scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            LocalizedText("One square sheet · 5 min 35 sec")
                .font(.subheadline.weight(.semibold)).foregroundStyle(PulsePlayerStyle.secondary)
            LocalizedText("Take a square sheet. Follow the whole lesson or jump to the fold you have in your hands.")
                .fixedSize(horizontal: false, vertical: true)
            ActionButton(title: "Play the crane lesson") {
                do {
                    error = nil
                    player = try library.paperCraneRoute()
                } catch { self.error = error.localizedDescription }
            }
            ForEach(CraneChapter.guide) { chapter in
                Button {
                    do {
                        error = nil
                        player = try library.paperCraneRoute(startingAt: chapter)
                    } catch { self.error = error.localizedDescription }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(verbatim: durationLabel(chapter.start))
                            .monospacedDigit().foregroundStyle(PulsePlayerStyle.secondary)
                            .environment(\.layoutDirection, .leftToRight)
                        LocalizedText(chapter.title).multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                Divider()
            }
            VStack(alignment: .leading, spacing: 2) {
                LocalizedText("Film by Tavin. Re-encoded for iOS. Preview taken from the film.")
                    .font(.caption)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) { sourceLinks }
                    VStack(alignment: .leading, spacing: 0) { sourceLinks }
                }
            }.foregroundStyle(PulsePlayerStyle.secondary)
        }
    }

    @ViewBuilder private var sourceLinks: some View {
        if let source = URL(string: "https://commons.wikimedia.org/wiki/File:OrigamiCrane.ogv"),
           let license = URL(string: "https://creativecommons.org/licenses/by/3.0/") {
            Link(destination: source) { LocalizedText("Original film").frame(minHeight: 44) }
            Link(destination: license) { Text(verbatim: "CC BY 3.0").frame(minHeight: 44) }
        }
    }

    private func session(_ entry: FoldPracticeEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: entry.clip.title).font(.headline)
            HStack(alignment: .firstTextBaseline) {
                LocalizedText(entry.finishedAt == nil ? "In practice" : "Completed")
                Text(entry.updatedAt, style: .date)
            }.font(.caption).foregroundStyle(PulsePlayerStyle.secondary)
            ForEach(Array(entry.steps.enumerated()), id: \.element.id) { offset, step in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: durationLabel(step.start, fractional: true))
                        .monospacedDigit().foregroundStyle(PulsePlayerStyle.secondary)
                    if let name = step.displayName(), !name.isEmpty {
                        Text(verbatim: name)
                    } else {
                        LocalizedText("Fold %@", String(offset + 1))
                    }
                }.font(.subheadline).padding(.vertical, 2)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) { sessionActions(entry) }
                VStack(alignment: .leading, spacing: 0) { sessionActions(entry) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func sessionActions(_ entry: FoldPracticeEntry) -> some View {
        Button {
            error = nil
            if let route = entry.route(library: library, offline: offline) { player = route }
            else { error = "This video is no longer in the library." }
        } label: {
            LocalizedText(entry.finishedAt == nil ? "Resume practice" : "Review folds")
                .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
        }
        Button {
            clipEntry = entry
        } label: {
            LocalizedText("Export a fold").font(.subheadline).frame(minHeight: 44)
        }.buttonStyle(PressStyle())
        Button {
            export = FoldTimesCSV(entry)
            exporting = true
        } label: {
            LocalizedText("Export fold times").font(.subheadline).frame(minHeight: 44)
        }
    }
}

private struct FoldClipExportView: View {
    let entry: FoldPracticeEntry
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var commerce: CommerceStore
    @EnvironmentObject private var offline: OfflineStore
    @State private var selectedID: UUID
    @State private var working: Task<Void, Never>?
    @State private var preparingSource = false
    @State private var saved: PracticeRecording?
    @State private var sharing: SharedFile?
    @State private var showingPlus = false
    @State private var error: String?

    init(entry: FoldPracticeEntry) {
        self.entry = entry
        _selectedID = State(initialValue: entry.currentStep?.id ?? entry.steps.first?.id ?? entry.selectedID)
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeading(title: "Export a fold") { dismiss() }.disabled(working != nil)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(verbatim: entry.clip.title).font(.capture(.headline))
                    ForEach(Array(entry.steps.enumerated()), id: \.element.id) { offset, step in
                        Button {
                            guard selectedID != step.id else { return }
                            selectedID = step.id
                            error = nil
                            saved = nil
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: name(for: step, at: offset))
                                    .font(.capture(.subheadline, weight: .semibold))
                                HStack {
                                    if let duration = entry.duration ?? entry.clip.duration,
                                       let range = entry.loopRange(for: step, duration: duration) {
                                        Text(verbatim: durationLabel(range.lowerBound, fractional: true) + " – " + durationLabel(range.upperBound, fractional: true))
                                            .monospacedDigit()
                                    }
                                    if selectedID == step.id { LocalizedText("Selected") }
                                }.font(.capture(.caption)).foregroundStyle(PulsePlayerStyle.secondary)
                            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(PressStyle()).disabled(working != nil)
                            .accessibilityAddTraits(selectedID == step.id ? .isSelected : [])
                        Divider()
                    }
                    if let saved {
                        SavedVideoExport(movie: saved, sharing: working != nil) { share(saved) }
                    } else if working != nil {
                        AccountLoadingIndicator(title: preparingSource ? "Preparing export…" : "Exporting…")
                        Button("Cancel export") { working?.cancel() }.buttonStyle(CompactActionStyle())
                    } else if let index = entry.steps.firstIndex(where: { $0.id == selectedID }) {
                        if case .lesson = entry.id, offline.cached(entry.clip.id)?.isHLS != false {
                            LocalizedText("We download the video before exporting. Existing downloads are reused.")
                                .font(.capture(.footnote)).foregroundStyle(PulsePlayerStyle.secondary)
                        }
                        ActionButton(title: "Save fold as MP4") { save(entry.steps[index], at: index) }
                    }
                    if let error { ErrorNote(message: error) }
                }.pulsePlayerPage()
            }
        }
        .foregroundStyle(PulsePlayerStyle.paper).pulsePlayerScreenBackground()
        .sheet(item: $sharing) { ShareSheet(items: [$0.url]) }
        .fullScreenCover(isPresented: $showingPlus) { MembershipView(entry: .foldVideo) }
        .interactiveDismissDisabled(working != nil)
        .onDisappear { working?.cancel() }
    }

    private func name(for step: FoldPracticeStep, at index: Int) -> String {
        let language = AppLanguage.from(locale)
        return step.displayName(language: language) ?? L10n.format("Fold %@", [String(index + 1)], language: language)
    }

    private func save(_ step: FoldPracticeStep, at index: Int) {
        guard working == nil else { return }
        error = nil
        guard let authorization = try? commerce.requireMediaExport() else { showingPlus = true; return }
        let title = entry.clip.title + " · " + name(for: step, at: index)
        working = Task { @MainActor in
            defer { working = nil; preparingSource = false }
            let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
            defer { try? FileManager.default.removeItem(at: output) }
            do {
                let clip: LessonClip
                switch entry.id {
                case .movie:
                    guard let local = entry.route(library: library, offline: offline)?.clips.first else {
                        throw PulsePlayerError.service("This video is no longer in the library.")
                    }
                    clip = local
                case .lesson(_, let recordOwner, _):
                    guard recordOwner == authorization.owner else { throw PulsePlayerError.unauthorized }
                    clip = entry.clip
                }
                preparingSource = true
                let source = try await offline.editableSource(for: clip, authorization: authorization)
                preparingSource = false
                try Task.checkCancellation()
                try await VideoEditor.writeFold(step, in: entry, source: source, destination: output)
                try Task.checkCancellation()
                saved = try await library.saveExport(output, title: title, authorization: authorization, commerce: commerce)
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    private func share(_ movie: PracticeRecording) {
        guard working == nil else { return }
        error = nil
        guard commerce.canExportMedia else { showingPlus = true; return }
        working = Task {
            defer { working = nil }
            do {
                let url = try await library.shareFile(for: movie, commerce: commerce)
                try Task.checkCancellation()
                sharing = SharedFile(url: url)
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
}

private struct FoldTimesCSV: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    private let data: Data

    init(_ entry: FoldPracticeEntry) {
        let columns = ["Video", "Fold", "Name", "Start (s)", "End (s)", "Resume (s)", "Updated", "Completed"]
        let date = ISO8601DateFormatter()
        var rows = [columns.map { L10n.text($0) }]
        for (i, step) in entry.steps.enumerated() {
            let duration = entry.duration ?? entry.clip.duration
            let end = duration.flatMap { entry.loopRange(for: step, duration: $0)?.upperBound }
            rows.append([entry.clip.title, String(i + 1), step.displayName() ?? "", String(step.start),
                         end.map { String($0) } ?? "", String(entry.resumeSeconds),
                         date.string(from: entry.updatedAt), entry.finishedAt.map { date.string(from: $0) } ?? ""])
        }
        let csv = rows.map { row in row.map(Self.cell).joined(separator: ",") }.joined(separator: "\r\n")
        data = Data(("\u{feff}" + csv + "\r\n").utf8)
    }

    private static func cell(_ value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        let prefix = text.first.map { "=+-@".contains($0) } == true ? "'" : ""
        return "\"" + prefix + escaped + "\""
    }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        data = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
