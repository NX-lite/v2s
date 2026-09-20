import SwiftUI

enum CorrectionSettingsForm {
    static func updating(
        _ settings: CorrectionSettings,
        _ update: (inout CorrectionSettings) -> Void
    ) -> CorrectionSettings {
        var updated = settings
        update(&updated)
        return updated
    }
}

@MainActor
enum CorrectionSettingsBindings {
    static func binding<Value>(
        for coordinator: RealtimeCorrectionCoordinator,
        keyPath: WritableKeyPath<CorrectionSettings, Value>
    ) -> Binding<Value> {
        Binding(
            get: { coordinator.settings[keyPath: keyPath] },
            set: { newValue in
                update(coordinator) { settings in
                    settings[keyPath: keyPath] = newValue
                }
            }
        )
    }

    static func update(
        _ coordinator: RealtimeCorrectionCoordinator,
        _ update: (inout CorrectionSettings) -> Void
    ) {
        coordinator.settings = CorrectionSettingsForm.updating(coordinator.settings, update)
    }
}

struct CorrectionSettingsSection: View {
    @ObservedObject var correction: RealtimeCorrectionCoordinator
    let interfaceLanguageID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(localized(.realtimeCorrection), systemImage: "waveform.badge.plus")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            Toggle(localized(.enableCorrection), isOn: settingsBinding(\.isEnabled))
                .toggleStyle(.switch)

            labeledField(localized(.apiKey)) {
                SecureField(localized(.apiKeyPlaceholder), text: settingsBinding(\.apiKey))
                    .textFieldStyle(.roundedBorder)
            }

            labeledField(localized(.apiBaseURL)) {
                TextField(localized(.apiBaseURLPlaceholder), text: settingsBinding(\.baseURL))
                    .textFieldStyle(.roundedBorder)
            }

            modelControls

            Divider()

            HStack(alignment: .firstTextBaseline) {
                Text(localized(.status))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(statusIsWarning ? .orange : .secondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Text(localized(.correctionPrivacyDisclosure))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modelControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            labeledField(localized(.model)) {
                TextField(localized(.modelPlaceholder), text: settingsBinding(\.model))
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 8) {
                if case .fetching = correction.modelFetchState {
                    ProgressView(localized(.fetchingModels))
                        .controlSize(.small)
                } else {
                    Button(localized(.fetchModels)) {
                        correction.fetchModels()
                    }
                    .buttonStyle(.bordered)
                }

                if case .fetched(let models) = correction.modelFetchState, models.isEmpty == false {
                    Menu {
                        ForEach(models, id: \.self) { modelName in
                            Button(modelName) {
                                updateSettings { settings in
                                    settings.model = modelName
                                }
                            }
                        }
                    } label: {
                        Label(localized(.model), systemImage: "chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                }

                Spacer(minLength: 0)

                if case .testing = correction.apiTestState {
                    ProgressView(localized(.testingAPI))
                        .controlSize(.small)
                } else {
                    Button(localized(.testAPI)) {
                        correction.testAPI()
                    }
                    .buttonStyle(.bordered)
                }
            }

            if case .failed(let detail) = correction.modelFetchState {
                failureText(detail)
            }
            switch correction.apiTestState {
            case .passed(let preview):
                Text(AppLocalization.string(.apiTestPassedFormat, languageID: interfaceLanguageID, preview))
                    .font(.caption)
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let detail):
                failureText(detail)
            case .idle, .testing:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func labeledField<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func failureText(_ detail: String?) -> some View {
        Text(detail.map { AppLocalization.correctionWarningText($0, languageID: interfaceLanguageID) }
            ?? localized(.correctionProviderFailure))
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var statusText: String {
        switch correction.status {
        case .disabled:
            localized(.idle)
        case .ready:
            localized(.ready)
        case .audio:
            localized(.audioCorrection)
        case .textOnly:
            localized(.textTranslationCorrection)
        case .warning(let detail):
            AppLocalization.correctionWarningText(detail, languageID: interfaceLanguageID)
        }
    }

    private var statusIsWarning: Bool {
        if case .warning = correction.status {
            return true
        }
        return false
    }

    private func settingsBinding<Value>(
        _ keyPath: WritableKeyPath<CorrectionSettings, Value>
    ) -> Binding<Value> {
        CorrectionSettingsBindings.binding(for: correction, keyPath: keyPath)
    }

    private func updateSettings(_ update: (inout CorrectionSettings) -> Void) {
        CorrectionSettingsBindings.update(correction, update)
    }

    private func localized(_ key: AppTextKey) -> String {
        AppLocalization.string(key, languageID: interfaceLanguageID)
    }
}
