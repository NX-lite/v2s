import SwiftUI

enum AssistantSettingsForm {
    static func updating(
        _ settings: AssistantSettings,
        _ update: (inout AssistantSettings) -> Void
    ) -> AssistantSettings {
        var updated = settings
        update(&updated)
        return updated
    }
}

struct AssistantSettingsSection: View {
    @ObservedObject var assistant: AssistantCoordinator
    let interfaceLanguageID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(localized(.assistant), systemImage: "sparkles")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

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

            Text(localized(.skills))
                .font(.callout)
                .foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                TextEditor(text: settingsBinding(\.skills))
                    .font(.body)
                    .accessibilityLabel(localized(.skills))
                if assistant.settings.skills.isEmpty {
                    Text(localized(.skillsPlaceholder))
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 88, maxHeight: 132)
            .padding(4)
            .background(.background, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(.separator, lineWidth: 1)
            }

            Toggle(localized(.autoDetectConversationLanguages), isOn: settingsBinding(\.autoDetectConversationLanguages))
                .toggleStyle(.switch)

            Divider()

            Text(localized(.hotKeys))
                .font(.callout.weight(.semibold))
            AssistantHotKeyRow(
                title: localized(.hotKeyFollowUp),
                binding: settingsBinding(\.followUpHotKey),
                error: hotKeyError(for: .followUp),
                interfaceLanguageID: interfaceLanguageID
            )
            AssistantHotKeyRow(
                title: localized(.hotKeyAsk),
                binding: settingsBinding(\.askHotKey),
                error: hotKeyError(for: .ask),
                interfaceLanguageID: interfaceLanguageID
            )
            AssistantHotKeyRow(
                title: localized(.hotKeySwitchMode),
                binding: settingsBinding(\.switchModeHotKey),
                error: hotKeyError(for: .switchMode),
                interfaceLanguageID: interfaceLanguageID
            )

            Divider()

            Text(localized(.assistantPrivacyDisclosure))
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
                if case .fetching = assistant.modelFetchState {
                    ProgressView(localized(.fetchingModels))
                        .controlSize(.small)
                } else {
                    Button(localized(.fetchModels)) {
                        assistant.fetchModels()
                    }
                    .buttonStyle(.bordered)
                }

                if case .fetched(let models) = assistant.modelFetchState, models.isEmpty == false {
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

                if case .testing = assistant.apiTestState {
                    ProgressView(localized(.testingAPI))
                        .controlSize(.small)
                } else {
                    Button(localized(.testAPI)) {
                        assistant.testAPI()
                    }
                    .buttonStyle(.bordered)
                }
            }

            if case .failed(let failure) = assistant.modelFetchState {
                failureText(failure)
            }
            switch assistant.apiTestState {
            case .passed(let preview):
                Text(AppLocalization.string(.apiTestPassedFormat, languageID: interfaceLanguageID, preview))
                    .font(.caption)
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let failure):
                failureText(failure)
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

    private func failureText(_ failure: AssistantFailure) -> some View {
        Text(AppLocalization.assistantFailureText(failure, languageID: interfaceLanguageID))
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func settingsBinding<Value>(
        _ keyPath: WritableKeyPath<AssistantSettings, Value>
    ) -> Binding<Value> {
        Binding(
            get: { assistant.settings[keyPath: keyPath] },
            set: { newValue in
                updateSettings { settings in
                    settings[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func updateSettings(_ update: (inout AssistantSettings) -> Void) {
        assistant.settings = AssistantSettingsForm.updating(assistant.settings, update)
    }

    private func hotKeyError(for action: GlobalHotKeyAction) -> HotKeyRegistrationError? {
        if let registeredError = assistant.hotKeyRegistrationErrors[action] {
            return registeredError
        }

        let settings = assistant.settings
        return GlobalHotKeyController.makePlan(
            followUp: settings.followUpHotKey,
            ask: settings.askHotKey,
            switchMode: settings.switchModeHotKey
        ).errors[action]
    }

    private func localized(_ key: AppTextKey) -> String {
        AppLocalization.string(key, languageID: interfaceLanguageID)
    }
}

private struct AssistantHotKeyRow: View {
    let title: String
    let binding: Binding<HotKeyBinding>
    let error: HotKeyRegistrationError?
    let interfaceLanguageID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Picker(title, selection: keyBinding) {
                    ForEach(HotKeyBinding.allowedKeys, id: \.self) { key in
                        Text(key.uppercased()).tag(key)
                    }
                }
                .labelsHidden()
                .frame(width: 64)

                modifierToggle("⌘", keyPath: \.useCommand)
                modifierToggle("⌥", keyPath: \.useOption)
                modifierToggle("⌃", keyPath: \.useControl)
                modifierToggle("⇧", keyPath: \.useShift)
                Spacer(minLength: 0)
                Text(binding.wrappedValue.displayString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            if let error {
                Text(AppLocalization.hotKeyRegistrationErrorText(error, languageID: interfaceLanguageID))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var keyBinding: Binding<String> {
        Binding(
            get: { binding.wrappedValue.normalizedKey },
            set: { key in
                var updated = binding.wrappedValue
                updated.key = key
                binding.wrappedValue = updated
            }
        )
    }

    private func modifierToggle(
        _ title: String,
        keyPath: WritableKeyPath<HotKeyBinding, Bool>
    ) -> some View {
        Toggle(
            title,
            isOn: Binding(
                get: { binding.wrappedValue[keyPath: keyPath] },
                set: { enabled in
                    var updated = binding.wrappedValue
                    updated[keyPath: keyPath] = enabled
                    binding.wrappedValue = updated
                }
            )
        )
        .toggleStyle(.checkbox)
        .accessibilityLabel(title)
    }
}
