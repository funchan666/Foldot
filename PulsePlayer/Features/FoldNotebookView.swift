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
                    if let name = step.name, !name.isEmpty {
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
            export = FoldTimesCSV(entry)
            exporting = true
        } label: {
            LocalizedText("Export fold times").font(.subheadline).frame(minHeight: 44)
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
            rows.append([entry.clip.title, String(i + 1), step.name ?? "", String(step.start),
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
