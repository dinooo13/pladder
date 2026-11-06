import SwiftUI
import PladderCore
import PladderRefine
import PladderSystem

struct TextSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                ForEach(StandardProcessors.entries.map(\.id).filter(StandardProcessors.switchable.contains), id: \.self) { id in
                    Toggle(isOn: binding(for: id)) {
                        ToggleLabel(title: ProcessorText.name(id), detail: ProcessorText.detail(id))
                    }
                }
                Toggle(isOn: $model.settings.appendTrailingSpace) {
                    ToggleLabel(
                        title: String(localized: "Add a space after each dictation"),
                        detail: String(localized: "So the next dictation does not run into this one."))
                }
            } header: {
                Text("Cleanup")
            }

            Section {
                Toggle(isOn: $model.settings.shortSentenceWithoutPeriod) {
                    ToggleLabel(
                        title: String(localized: "No period"),
                        detail: String(localized: "“Yes.” is pasted as “Yes”."))
                }
                Toggle(isOn: $model.settings.shortSentenceWithoutCapital) {
                    ToggleLabel(
                        title: String(localized: "No capital"),
                        detail: String(localized: "“Run the tests” is pasted as “run the tests”. “I” and “API” keep theirs."))
                }
            } header: {
                Text("Short replies")
            } footer: {
                FootnoteText("For a dictation of one sentence up to ten words, such as a reply to an agent.")
            }

            Section {
                Toggle(isOn: $model.settings.polishDictations) {
                    ToggleLabel(
                        title: String(localized: "Polish with on-device AI"),
                        detail: String(localized: "Fixes self-corrections, lists and punctuation before pasting."))
                }
                Picker("Model", selection: $model.settings.polishModel) {
                    ForEach(PolishModel.allCases, id: \.self) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                .disabled(!model.settings.polishDictations)
                polishModelStatus
            } header: {
                HStack(spacing: 6) {
                    Text("Polish")
                    Text("Beta")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .overlay(Capsule().strokeBorder(.separator))
                }
            } footer: {
                FootnoteText(verbatim: model.settings.polishModel.summary)
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
        } else if model.settings.polishDictations, let warning = model.polish.availability.polishWarning {
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
