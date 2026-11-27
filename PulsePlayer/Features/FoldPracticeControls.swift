import SwiftUI

struct FoldPracticeControls: View {
    @Environment(\.locale) private var locale
    @ObservedObject private var notebook = FoldPracticeStore.shared
    let clip: LessonClip
    let identity: FoldPracticeID
    @ObservedObject var playback: PlaybackController
    let enabled: Bool
    let didInteract: () -> Void
    let resumePlayback: () -> Void
    let showSteps: () -> Void
    @State private var feedback: String?

    var body: some View {
        let entry = notebook.entry(for: identity)
        let range = entry.flatMap { entry in
            entry.currentStep.flatMap { entry.loopRange(for: $0, duration: playback.timeline.duration) }
        }
        VStack(alignment: .leading, spacing: 2) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    markButton.fixedSize(horizontal: true, vertical: false)
                    loopButton(range).fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                    notesButton
                }
                VStack(alignment: .leading, spacing: 0) {
                    markButton
                    HStack(spacing: 6) {
                        loopButton(range)
                        Spacer(minLength: 0)
                        notesButton
                    }
                }
            }
            if let message = feedback ?? playback.foldNotice ?? notebook.error {
                LocalizedText(message).font(.capture(.caption))
                    .foregroundStyle(PulsePlayerStyle.mediaSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 4)
    }

    private var markButton: some View {
        Button {
            didInteract()
            do {
                guard let seconds = playback.foldPosition else {
                    throw PulsePlayerError.service("Wait for the video to finish seeking.")
                }
                try notebook.mark(clip, id: identity, seconds: seconds, duration: playback.timeline.duration)
                playback.stopRepeating()
                feedback = nil
            } catch { feedback = error.localizedDescription }
        } label: {
            LocalizedText("Mark this fold")
                .font(.capture(.subheadline, weight: .semibold))
                .foregroundStyle(PulsePlayerStyle.mediaBackdrop)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(PulsePlayerStyle.mediaAccent, in: Capsule())
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .disabled(!enabled || playback.error != nil)
        .accessibilityIdentifier("practice.markFold")
    }

    @ViewBuilder private func loopButton(_ range: ClosedRange<Double>?) -> some View {
        if let range, playback.foldGuide == nil {
            let looping = playback.repeatedRange != nil
            Button {
                didInteract()
                do {
                    if looping {
                        playback.stopRepeating()
                    } else {
                        try notebook.setFinished(false, in: identity)
                        playback.prepareRepeat(range)
                        if !playback.intendsPlayback { resumePlayback() }
                    }
                    feedback = nil
                } catch { feedback = error.localizedDescription }
            } label: {
                LocalizedText(looping ? "Stop loop" : "Loop this fold")
                    .font(.capture(.subheadline, weight: .semibold))
                    .foregroundStyle(PulsePlayerStyle.mediaAccent)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 6).frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .disabled(!enabled || playback.error != nil)
            .accessibilityIdentifier("practice.loopFold")
        }
    }

    private var notesButton: some View {
        Button {
            feedback = nil
            showSteps()
        } label: {
            HStack(spacing: 6) {
                if let guide = playback.foldGuide {
                    LocalizedText("Play %@ of %@", String(guide.pass), String(guide.playsPerFold))
                        .font(.capture(.subheadline)).monospacedDigit()
                }
                Glyph(symbol: .fold, size: 18, tint: PulsePlayerStyle.onDark)
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle()).disabled(!enabled)
        .accessibilityLabel(LocalizedStringKey("Fold notes"))
        .accessibilityValue(Text(verbatim: playback.foldGuide.map {
            L10n.format("Play %@ of %@", [String($0.pass), String($0.playsPerFold)], language: .from(locale))
        } ?? ""))
        .accessibilityHint(LocalizedStringKey("Open the list of marked folds"))
        .accessibilityIdentifier("practice.openFolds")
    }
}

/// The existing player pauses when presenting this panel. Seeking and loop setup use that same player.
struct FoldPracticePanel: View {
    @ObservedObject private var notebook = FoldPracticeStore.shared
    let identity: FoldPracticeID
    @ObservedObject var playback: PlaybackController
    let close: (_ resume: Bool) -> Void
    @Environment(\.locale) private var locale
    @State private var feedback: String?
    @State private var editingName = false
    @State private var draft = ""
    @AppStorage(FoldGuidePlayback.preferenceKey) private var storedPlays = 2

    private var plays: Int { FoldGuidePlayback.playCounts.contains(storedPlays) ? storedPlays : 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let entry = notebook.entry(for: identity), let current = entry.currentStep {
                let range = entry.loopRange(for: current, duration: playback.timeline.duration)
                HStack(spacing: 12) {
                    action("Play from this fold") {
                        perform {
                            try notebook.setFinished(false, in: identity)
                            playback.stopRepeating()
                            playback.seek(current.start)
                            close(true)
                        }
                    }
                    GlassActionMenu(title: "Fold notes", onDark: true, items: foldActions(entry, current: current)) {
                        LocalizedText("More").font(.capture(.subheadline, weight: .semibold))
                            .foregroundStyle(PulsePlayerStyle.mediaAccent)
                            .padding(.horizontal, 10).frame(minWidth: 44, minHeight: 44)
                    }
                }
                if editingName {
                    TextField(L10n.text("Fold name", language: .from(locale)), text: $draft)
                        .textFieldStyle(.plain).font(.capture(.body)).padding(12)
                        .background(PulsePlayerStyle.onDark.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                        .submitLabel(.done)
                        .onSubmit { saveName() }
                    action("Save name", perform: saveName)
                }
                if let range {
                    if playback.foldGuide == nil {
                        let looping = playback.repeatedRange != nil
                        Button {
                            perform {
                                if looping {
                                    playback.stopRepeating()
                                } else {
                                    try notebook.setFinished(false, in: identity)
                                    playback.prepareRepeat(range)
                                }
                                close(true)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                LocalizedText(looping ? "Stop loop" : "Loop this fold")
                                    .font(.capture(.subheadline, weight: .semibold))
                                    .foregroundStyle(PulsePlayerStyle.mediaAccent)
                                Spacer(minLength: 0)
                                Text(verbatim: durationLabel(range.lowerBound, fractional: true) + " – " +
                                     durationLabel(range.upperBound, fractional: true))
                                    .monospacedDigit().font(.capture(.footnote)).foregroundStyle(PulsePlayerStyle.mediaSecondary)
                            }
                            .frame(minHeight: 44).contentShape(Rectangle())
                        }.buttonStyle(PressStyle())
                    }
                    handsFreeControls
                }
                Divider()
                ForEach(Array(entry.steps.enumerated()), id: \.element.id) { index, step in
                    let selected = step.id == current.id
                    Button {
                        perform {
                            try notebook.select(step, in: identity)
                            playback.stopRepeating()
                            playback.seek(step.start)
                            editingName = false
                        }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Group {
                                if let name = step.displayName(language: .from(locale)) {
                                    Text(verbatim: name)
                                } else {
                                    LocalizedText("Fold %@", String(index + 1))
                                }
                            }
                            .font(.capture(.subheadline, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? PulsePlayerStyle.mediaAccent : PulsePlayerStyle.onDark)
                            Spacer(minLength: 8)
                            if selected {
                                Glyph(symbol: .bookmark, size: 13, tint: PulsePlayerStyle.mediaAccent)
                            }
                            Text(verbatim: durationLabel(step.start, fractional: true))
                                .font(.capture(.footnote)).monospacedDigit()
                        }
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .multilineTextAlignment(.leading).contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle())
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityValue(selected ? Text(LocalizedStringKey(entry.finishedAt == nil ? "Resume here" : "Completed")) : Text(verbatim: ""))
                    Divider()
                }

            } else {
                EmptyStateScene(appearance: .notebook,
                                message: "When a fold begins, tap Mark this fold in the player. Your marks are saved on this device.",
                                onMedia: true)
            }
            if let message = feedback ?? notebook.error {
                LocalizedText(message).font(.capture(.footnote)).foregroundStyle(PulsePlayerStyle.mediaSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func foldActions(_ entry: FoldPracticeEntry, current: FoldPracticeStep) -> [ActionMenuItem] {
        [
            ActionMenuItem("Set loop end here", .bookmark) {
                perform {
                    guard let position = playback.foldPosition else {
                        throw PulsePlayerError.service("Wait for the video to finish seeking.")
                    }
                    try notebook.updateEnd(in: identity, at: position, duration: playback.timeline.duration)
                    playback.stopRepeating()
                }
            },
            ActionMenuItem("Name this fold", .edit) {
                draft = current.displayName(language: .from(locale)) ?? ""
                editingName = true
            },
            ActionMenuItem(entry.finishedAt == nil ? "Finish practice" : "Reopen practice", .fold) {
                perform {
                    try notebook.setFinished(entry.finishedAt == nil, in: identity)
                    playback.stopRepeating()
                    close(false)
                }
            },
            ActionMenuItem("Unmark", .close, destructive: true) {
                perform {
                    try notebook.removeMark(current.id, in: identity)
                    playback.stopRepeating()
                    editingName = false
                }
            },
            ActionMenuItem("Undo last mark", .back, destructive: true) {
                perform {
                    try notebook.undoLastMark(in: identity)
                    playback.stopRepeating()
                    editingName = false
                }
            }
        ]
    }

    private var repeatChoices: [ActionMenuItem] {
        FoldGuidePlayback.playCounts.map { count in
            let title = L10n.format("Plays per fold · %@", [count.formatted(.number.locale(locale))], language: .from(locale))
            return ActionMenuItem(title, .play, selected: plays == count, identifier: "practice.guide.plays.\(count)") {
                storedPlays = count
            }
        }
    }

    @ViewBuilder private var handsFreeControls: some View {
        if let guide = playback.foldGuide {
            LocalizedText("Play %@ of %@", String(guide.pass), String(guide.playsPerFold))
                .font(.capture(.footnote)).foregroundStyle(PulsePlayerStyle.mediaSecondary)
            action("Stop hands-free practice") {
                playback.stopRepeating()
                close(false)
            }
            .accessibilityIdentifier("practice.guide.stop")
        } else {
            HStack(spacing: 8) {
                action("Play folds hands-free") {
                    perform {
                        try playback.prepareFoldGuide(for: identity, playsPerFold: plays)
                        close(true)
                    }
                }
                .accessibilityHint(LocalizedStringKey("The video starts at this fold and pauses after the last one."))
                .accessibilityIdentifier("practice.guide.start")
                GlassActionMenu(title: "Plays per fold", onDark: true, items: repeatChoices) {
                    HStack(spacing: 6) {
                        Text(verbatim: "×" + plays.formatted(.number.locale(locale)))
                            .font(.capture(.subheadline, weight: .semibold)).monospacedDigit()
                        Glyph(symbol: .back, size: 9, tint: PulsePlayerStyle.mediaAccent)
                            .environment(\.layoutDirection, .leftToRight).rotationEffect(.degrees(-90))
                    }
                    .padding(.horizontal, 8).frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel(LocalizedStringKey("Plays per fold"))
                .accessibilityValue(Text(verbatim: plays.formatted(.number.locale(locale))))
            }
        }
    }

    private func action(_ title: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            LocalizedText(title).font(.capture(.subheadline, weight: .semibold))
                .foregroundStyle(PulsePlayerStyle.mediaAccent)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    private func perform(_ operation: () throws -> Void) {
        do {
            try operation()
            feedback = nil
        } catch { feedback = error.localizedDescription }
    }

    private func saveName() {
        perform {
            try notebook.renameCurrent(in: identity, name: draft)
            editingName = false
        }
    }
}
