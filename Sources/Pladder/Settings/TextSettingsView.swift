import SwiftUI
import PladderCore
import PladderRefine
import PladderSystem

struct TextSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Cleanup") {
                ForEach(StandardProcessors.entries.map(\.id).filter(StandardProcessors.switchable.contains), id: \.self) { id in
                    Toggle(isOn: binding(for: id)) {
                        Text(ProcessorText.name(id))
                        Text(ProcessorText.detail(id))
                    }
                }
                Toggle(isOn: $model.settings.appendTrailingSpace) {
                    Text("Add a space after each dictation")
                    Text("So the next dictation does not run into this one.")
                }
            }

            Section {
                Toggle(isOn: $model.settings.shortSentenceWithoutPeriod) {
                    Text("Drop the final period")
                    Text("“Yes.” is pasted as “Yes”.")
                }
                Toggle(isOn: $model.settings.shortSentenceWithoutCapital) {
                    Text("Start with a lowercase letter")
                    Text("“Run the tests” is pasted as “run the tests”. “I” and “API” keep theirs.")
                }
            } header: {
                Text("Short replies")
            } footer: {
                Text("For a dictation of one sentence up to ten words, such as a reply to an agent.")
            }

            Section {
                Toggle(isOn: $model.settings.polishDictations) {
                    Text("Polish with on-device AI")
                    Text("Fixes self-corrections, lists and punctuation before pasting.")
                }
                if model.settings.polishDictations {
                    Picker("Model", selection: $model.settings.polishModel) {
                        ForEach(PolishModel.allCases, id: \.self) { choice in
                            Text(choice.displayName).tag(choice)
                        }
                    }
                    polishModelStatus
                }
            } header: {
                Text("Polish (Beta)")
            } footer: {
                if model.settings.polishDictations {
                    Text(verbatim: model.settings.polishModel.summary)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var polishModelStatus: some View {
        if let status = model.polish.status {
            switch status {
            case .ready, .missing:
                EmptyView()
            case .downloading(let fraction):
                ProgressView(value: fraction) {
                    Text("Downloading \(model.settings.polishModel.displayName)…")
                } currentValueLabel: {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                }
            case .verifying:
                ProgressView {
                    Text("Checking the download…")
                }
            case .failed(let failure):
                LabeledContent {
                    Button("Try Again") { model.polish.retryDownload() }
                } label: {
                    WarningLabel(failure.text)
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
