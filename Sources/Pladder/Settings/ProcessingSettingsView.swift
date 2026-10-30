import SwiftUI
import PladderCore
import PladderRefine
import PladderSystem

struct ProcessingSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                ForEach(StandardProcessors.entries.map(\.id), id: \.self) { id in
                    Toggle(isOn: binding(for: id)) {
                        ToggleLabel(title: ProcessorText.name(id), detail: ProcessorText.detail(id))
                    }
                }
            } header: {
                Text("Processors")
            } footer: {
                FootnoteText("Each dictation runs through these in order before it is inserted.")
            }

            Section {
                Toggle(isOn: $model.settings.appendTrailingSpace) {
                    ToggleLabel(
                        title: String(localized: "Append a space after each dictation"),
                        detail: String(localized: "Separates consecutive dictations so pasted runs stay readable."))
                }
                Toggle(isOn: $model.settings.shortSentenceWithoutPeriod) {
                    ToggleLabel(
                        title: String(localized: "Leave out the period after a short sentence"),
                        detail: String(localized: "A dictation of one sentence up to ten words, such as “Yes” or a command, is pasted without its final period."))
                }
                Toggle(isOn: $model.settings.shortSentenceWithoutCapital) {
                    ToggleLabel(
                        title: String(localized: "Start a short sentence in lowercase"),
                        detail: String(localized: "A dictation of one sentence up to ten words is pasted without its first capital. “I” and words such as “API” keep theirs."))
                }
            } header: {
                Text("Output")
            }

            Section {
                Toggle("Polish dictations", isOn: $model.settings.polishDictations)
                Picker("Model", selection: $model.settings.polishModel) {
                    ForEach(PolishModel.allCases, id: \.self) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                polishModelStatus
            } header: {
                Text("Experimental")
            } footer: {
                FootnoteText("Before the text is pasted, the model cleans it up on this Mac: self-corrections, spoken punctuation, lists. Apple Intelligence adds one to two seconds to every dictation, S1-mini by Superwhisper about half a second. S1-mini is trained on English, also handles German and Spanish, and is downloaded once from Hugging Face when you pick it. Anything a model cannot fix is pasted as dictated.")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var polishModelStatus: some View {
        if let status = model.polish.status {
            switch status {
            case .ready:
                EmptyView()
            case .missing:
                FootnoteText("Downloads when polish is on.")
            case .downloading(let fraction):
                ProgressView(value: fraction) {
                    Text("Downloading \(model.settings.polishModel.displayName)…")
                        .font(.callout)
                } currentValueLabel: {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                }
            case .verifying:
                ProgressView {
                    Text("Checking the download…").font(.callout)
                }
            case .failed(let failure):
                HStack(alignment: .firstTextBaseline) {
                    WarningLabel(failure.text)
                    Spacer()
                    Button("Try Again") { model.polish.retryDownload() }
                }
            }
        } else if let warning = model.polish.availability.polishWarning {
            WarningLabel(warning)
        }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { !model.settings.disabledProcessors.contains(id) },
            set: { model.settings.setProcessor(id, enabled: $0) }
        )
    }
}

private struct ToggleLabel: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
