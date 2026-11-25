import SwiftUI

struct FoldPracticeControls: View {
    @ObservedObject private var notebook = FoldPracticeStore.shared
    let clip: LessonClip
    let identity: FoldPracticeID
    @ObservedObject var playback: PlaybackController
    let enabled: Bool
    let didInteract: () -> Void
    let showSteps: () -> Void
    @State private var feedback: String?

    var body: some View {
        let entry = notebook.entry(for: identity)
        VStack(alignment: .leading, spacing: 2) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    markButton
                    Spacer(minLength: 4)
                    stepsButton(entry)
                }
                VStack(alignment: .leading, spacing: 0) {
                    markButton
                    stepsButton(entry)
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

    private func stepsButton(_ entry: FoldPracticeEntry?) -> some View {
        Button {
            feedback = nil
            showSteps()
        } label: {
            Group {
                if let entry, let guide = playback.foldGuide {
                    LocalizedText("Fold %@ of %@ · play %@ of %@", String(entry.currentStepNumber), String(entry.steps.count),
                                  String(guide.pass), String(guide.playsPerFold))
                } else if let entry, playback.repeatedRange != nil {
                    LocalizedText("Looping fold %@ of %@", String(entry.currentStepNumber), String(entry.steps.count))
                } else {
                    LocalizedText("Fold notes")
                }
            }
            .font(.capture(.subheadline, weight: .medium))
            .multilineTextAlignment(.leading)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .disabled(!enabled)
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
                if range != nil {
                    handsFreeControls
                    Divider()
                }
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
                            VStack(alignment: .leading, spacing: 3) {
                                LocalizedText("Fold %@", String(index + 1)).font(.capture(.subheadline, weight: .semibold))
                                if let name = step.displayName(language: .from(locale)) {
                                    Text(verbatim: name).font(.capture(.footnote))
                                }
                                if selected {
                                    LocalizedText(entry.finishedAt == nil ? "Resume here" : "Completed")
                                        .font(.capture(.caption)).foregroundStyle(PulsePlayerStyle.mediaAccent)
                                }
                            }
                            Spacer(minLength: 8)
                            Text(verbatim: durationLabel(step.start, fractional: true))
                                .font(.capture(.footnote)).monospacedDigit()
                        }
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .multilineTextAlignment(.leading).contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle())
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    Divider()
                }

                if let range, playback.foldGuide == nil {
                    let limits = durationLabel(range.lowerBound, fractional: true) + " – " + durationLabel(range.upperBound, fractional: true)
                    LocalizedText("Fold loop · %@", limits)
                        .font(.capture(.footnote)).foregroundStyle(PulsePlayerStyle.mediaSecondary)
                        .padding(.top, 8)
                    if playback.repeatedRange != nil {
                        action("Stop loop") {
                            playback.stopRepeating()
                            close(true)
                        }
                    } else {
                        action("Loop this fold") {
                            perform {
                                try notebook.setFinished(false, in: identity)
                                playback.prepareRepeat(range)
                                close(true)
                            }
                        }
                    }
                }
                action("Set loop end here") {
                    perform {
                        guard let position = playback.foldPosition else {
                            throw PulsePlayerError.service("Wait for the video to finish seeking.")
                        }
                        try notebook.updateEnd(in: identity, at: position, duration: playback.timeline.duration)
                        playback.stopRepeating()
                    }
                }
                action("Play from this fold") {
                    perform {
                        try notebook.setFinished(false, in: identity)
                        playback.stopRepeating()
                        playback.seek(current.start)
                        close(true)
                    }
                }
                Divider()
                if editingName {
                    TextField(L10n.text("Fold name", language: .from(locale)), text: $draft)
                        .textFieldStyle(.plain).font(.capture(.body)).padding(12)
                        .background(PulsePlayerStyle.onDark.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                        .submitLabel(.done)
                        .onSubmit { saveName() }
                    action("Save name", perform: saveName)
                } else {
                    action("Name this fold") {
                        draft = current.displayName(language: .from(locale)) ?? ""
                        editingName = true
                    }
                }
                action("Undo last mark") {
                    perform {
                        try notebook.undoLastMark(in: identity)
                        playback.stopRepeating()
                        editingName = false
                    }
                }
                action(entry.finishedAt == nil ? "Finish practice" : "Reopen practice") {
                    perform {
                        try notebook.setFinished(entry.finishedAt == nil, in: identity)
                        playback.stopRepeating()
                        close(false)
                    }
                }
            } else {
                LocalizedText("When a fold begins, tap Mark this fold in the player. Your marks are saved on this device.")
                    .font(.capture(.body)).fixedSize(horizontal: false, vertical: true)
            }
            if let message = feedback ?? notebook.error {
                LocalizedText(message).font(.capture(.footnote)).foregroundStyle(PulsePlayerStyle.mediaSecondary)
                    .fixedSize(horizontal: false, vertical: true)
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
            LocalizedText("Plays per fold").font(.capture(.subheadline, weight: .semibold))
            HStack(spacing: 8) {
                ForEach(FoldGuidePlayback.playCounts, id: \.self) { count in
                    let selected = plays == count
                    let number = count.formatted(.number.locale(locale))
                    Button { storedPlays = count } label: {
                        Text(verbatim: number)
                            .font(.capture(.body, weight: selected ? .bold : .medium))
                            .foregroundStyle(selected ? PulsePlayerStyle.mediaBackdrop : PulsePlayerStyle.onDark)
                            .frame(minWidth: 44, minHeight: 44)
                            .background(selected ? PulsePlayerStyle.mediaAccent : PulsePlayerStyle.onDark.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(PressStyle())
                    .accessibilityLabel(Text(verbatim: L10n.format("Plays per fold · %@", [number], language: .from(locale))))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("practice.guide.plays.\(count)")
                }
            }
            action("Play folds hands-free") {
                perform {
                    try playback.prepareFoldGuide(for: identity, playsPerFold: plays)
                    close(true)
                }
            }
            .accessibilityIdentifier("practice.guide.start")
            LocalizedText("The video starts at this fold and pauses after the last one.")
                .font(.capture(.caption)).foregroundStyle(PulsePlayerStyle.mediaSecondary)
                .fixedSize(horizontal: false, vertical: true)
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
