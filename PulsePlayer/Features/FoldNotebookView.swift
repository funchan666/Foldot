import SwiftUI
import UniformTypeIdentifiers

struct FoldNotebookView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var offline: OfflineStore
    @ObservedObject private var practice = FoldPracticeStore.shared
    @State private var player: PlayerRoute?
    @State private var error: String?
    @State private var export: FoldTimesCSV?
    @State private var exporting = false
    let openExport: (FoldPracticeEntry) -> Void
    @State private var importing = false

    var body: some View {
        let entries = practice.recent(owner: api.offlineOwnerID, library: library, offline: offline)
        ScenePage { container in
            let stacked = PulsePlayerStyle.pageContentWidth(in: container) < 320
                || PulsePlayerStyle.intersectsReservedRegion(CGRect(origin: .zero, size: container.size), in: container)
            LazyVStack(alignment: .leading, spacing: 18) {
                if let message = practice.error {
                    ErrorNote(message: message)
                    if practice.needsLoadRetry {
                        Button("Try again", action: practice.retryLoading).buttonStyle(CompactActionStyle())
                    }
                }
                if entries.isEmpty && !practice.needsLoadRetry {
                    EmptyStateScene(appearance: .notebook, title: "No folds marked yet", message: "Mark a fold in a video to return to it here.")
                    VideoImportActions(onImported: playImport, importing: $importing, presentation: .sources(stacked: stacked))
                        .pulsePlayerKeepControlsTogether()
                }
                ForEach(entries) { entry in
                    session(entry)
                }
                if let error { ErrorNote(message: error) }
            }
        }
        .sceneBack(context: "Practice notebook", disabled: importing) { dismiss() }
        .foregroundStyle(PulsePlayerStyle.paper)
        .pulsePlayerScreenBackground()
        .fullScreenCover(item: $player) { PlayerScreen(route: $0) }
        .fileExporter(isPresented: $exporting, document: export, contentType: .commaSeparatedText,
                      defaultFilename: "PulsePlayer-fold-times") { result in
            if case .failure(let problem) = result { error = problem.localizedDescription }
        }
    }

    private func playImport(_ movie: PracticeRecording) {
        guard let route = PlayerRoute.localMovies([movie], selected: movie, library: library) else {
            error = "This video file is no longer available."
            return
        }
        error = nil
        player = route
    }

    private func session(_ entry: FoldPracticeEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                FoldPracticeThumbnail(entry: entry)
                    .frame(width: 78, height: 62)
                    .clipShape(.rect(cornerRadius: 10))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: entry.clip.title).font(.capture(.headline))
                    LocalizedText(entry.finishedAt == nil ? "In practice" : "Completed")
                        .font(.capture(.footnote, weight: .semibold)).foregroundStyle(PulsePlayerStyle.accent)
                    Text(entry.updatedAt, style: .date).font(.capture(.caption)).foregroundStyle(PulsePlayerStyle.secondary)
                }
            }
            ForEach(Array(entry.steps.enumerated()), id: \.element.id) { offset, step in
                Button {
                    guard let route = entry.route(library: library, offline: offline) else {
                        error = "This video is no longer in the library."
                        return
                    }
                    do {
                        try practice.select(step, in: entry.id)
                        error = nil
                        player = route
                    } catch { self.error = error.localizedDescription }
                } label: {
                    HStack(spacing: 10) {
                        Text(verbatim: durationLabel(step.start)).monospacedDigit()
                            .foregroundStyle(PulsePlayerStyle.accent)
                        if let name = step.displayName(), !name.isEmpty {
                            Text(verbatim: name)
                        } else {
                            LocalizedText("Fold %@", String(offset + 1))
                        }
                        Spacer(minLength: 2)
                        Glyph(symbol: step.id == entry.selectedID ? .bookmark : .play, size: 14, tint: PulsePlayerStyle.accent)
                    }
                    .font(.capture(.subheadline)).multilineTextAlignment(.leading)
                    .frame(minHeight: 44).contentShape(Rectangle())
                    .overlay(alignment: .bottom) { Divider().accessibilityHidden(true) }
                }
                .buttonStyle(PressStyle())
                .accessibilityAddTraits(step.id == entry.selectedID ? .isSelected : [])
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { sessionActions(entry) }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 4) { sessionActions(entry) }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PulsePlayerStyle.surface, in: .rect(cornerRadius: 18))
        .pulsePlayerKeepControlsTogether()
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
        .buttonStyle(CompactActionStyle())
        GlassActionMenu(title: "Export", items: [
            ActionMenuItem("Export a fold", .edit) { openExport(entry) },
            ActionMenuItem("Export fold times", .download) {
                export = FoldTimesCSV(entry)
                exporting = true
            }
        ]) {
            HStack(spacing: 6) {
                Glyph(symbol: .download, size: 15, tint: PulsePlayerStyle.accent)
                LocalizedText("Export").font(.capture(.subheadline, weight: .medium))
            }
            .padding(.horizontal, 8).frame(minHeight: 44)
        }
    }
}

struct FoldClipExportView: View {
    let entry: FoldPracticeEntry
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var offline: OfflineStore
    @State private var selectedID: UUID
    @State private var working: Task<Void, Never>?
    @State private var preparingSource = false
    @State private var saved: PracticeRecording?
    @State private var sharing: SharedFile?
    @State private var error: String?

    init(entry: FoldPracticeEntry) {
        self.entry = entry
        _selectedID = State(initialValue: entry.currentStep?.id ?? entry.steps.first?.id ?? entry.selectedID)
    }

    var body: some View {
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
                    if case .lesson = entry.id, offline.cachedEditableFile(for: entry.clip.id) == nil {
                        LocalizedText("We download the video before exporting. Existing downloads are reused.")
                            .font(.capture(.footnote)).foregroundStyle(PulsePlayerStyle.secondary)
                    }
                    ActionButton(title: "Save fold as MP4") { save(entry.steps[index], at: index) }
                }
                if let error { ErrorNote(message: error) }
            }.pulsePlayerPage()
        }
        .sceneBack(context: "Export a fold", disabled: working != nil) { dismiss() }
        .foregroundStyle(PulsePlayerStyle.paper).pulsePlayerScreenBackground()
        .sheet(item: $sharing) { ShareSheet(items: [$0.url]) }
        .navigationBarBackButtonHidden(true)
        .onDisappear { working?.cancel() }
    }

    private func name(for step: FoldPracticeStep, at index: Int) -> String {
        let language = AppLanguage.from(locale)
        return step.displayName(language: language) ?? L10n.format("Fold %@", [String(index + 1)], language: language)
    }

    private func save(_ step: FoldPracticeStep, at index: Int) {
        guard working == nil else { return }
        error = nil
        let title = entry.clip.title + " · " + name(for: step, at: index)
        working = Task { @MainActor in
            defer { working = nil; preparingSource = false }
            let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
            defer { try? FileManager.default.removeItem(at: output) }
            do {
                let clip: LessonClip
                let owner: String?
                switch entry.id {
                case .movie:
                    guard let local = entry.route(library: library, offline: offline)?.clips.first else {
                        throw PulsePlayerError.service("This video is no longer in the library.")
                    }
                    clip = local
                    owner = nil
                case .lesson(_, let recordOwner, _):
                    clip = entry.clip
                    owner = recordOwner
                }
                preparingSource = true
                let source = try await offline.editableSource(for: clip, expectedOwner: owner)
                preparingSource = false
                try Task.checkCancellation()
                try await VideoEditor.writeFold(step, in: entry, source: source.url, destination: output)
                try Task.checkCancellation()
                saved = try await library.saveExport(output, title: title, beforeCommit: source.checkOwner)
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    private func share(_ movie: PracticeRecording) {
        guard working == nil else { return }
        error = nil
        working = Task {
            defer { working = nil }
            do {
                let url = try await library.shareFile(for: movie)
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
