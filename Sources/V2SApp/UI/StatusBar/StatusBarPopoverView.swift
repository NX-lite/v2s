import SwiftUI

struct StatusBarPopoverView: View {
    @ObservedObject var model: AppModel
    let openSettings: () -> Void
    let quitApp: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerSection
            sourceSection
            languageSection
            overlaySection
            footerSection
        }
        .padding(16)
        .frame(width: 380)
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("v2s")
                        .font(.headline)
                    Text(model.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(model.sessionBadgeText)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.quaternary, in: Capsule())
            }

            Button(model.sessionButtonTitle) {
                model.toggleSession()
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.selectedSource == nil)
        }
    }

    private var sourceSection: some View {
        GroupBox("Input Source") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Selected Source", selection: selectedSourceBinding) {
                    Text(model.allSources.isEmpty ? "No sources detected" : "Choose a source")
                        .tag(nil as String?)

                    ForEach(model.allSources) { source in
                        Text("\(source.category.displayName) · \(source.name)")
                            .tag(Optional(source.id))
                    }
                }
                .pickerStyle(.menu)

                Button("Refresh Sources") {
                    model.refreshSources()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var languageSection: some View {
        GroupBox("Languages") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Input", selection: inputLanguageBinding) {
                    ForEach(LanguageCatalog.common) { option in
                        Text(option.displayName).tag(option.id)
                    }
                }
                .pickerStyle(.menu)

                Picker("Subtitle", selection: outputLanguageBinding) {
                    ForEach(LanguageCatalog.common) { option in
                        Text(option.displayName).tag(option.id)
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    private var overlaySection: some View {
        GroupBox("Overlay") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button(model.isOverlayVisible ? "Hide Overlay" : "Show Preview") {
                        if model.isOverlayVisible {
                            model.toggleOverlayVisibility()
                        } else {
                            model.showOverlayPreview()
                        }
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Text(model.overlayStyle.clickThrough ? "Click-through" : "Interactive")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Opacity")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: overlayOpacityBinding, in: 0.16 ... 0.72)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Translated Font Size")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: translatedFontBinding, in: 16 ... 34)
                }
            }
        }
    }

    private var footerSection: some View {
        HStack {
            Button("Open Settings") {
                openSettings()
            }
            .buttonStyle(.bordered)

            Button("Quit") {
                quitApp()
            }
            .buttonStyle(.bordered)

            Spacer()

            if let source = model.selectedSource {
                Text(source.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var selectedSourceBinding: Binding<String?> {
        Binding(
            get: { model.selectedSourceID },
            set: { model.selectedSourceID = $0 }
        )
    }

    private var inputLanguageBinding: Binding<String> {
        Binding(
            get: { model.inputLanguageID },
            set: { model.inputLanguageID = $0 }
        )
    }

    private var outputLanguageBinding: Binding<String> {
        Binding(
            get: { model.outputLanguageID },
            set: { model.outputLanguageID = $0 }
        )
    }

    private var overlayOpacityBinding: Binding<Double> {
        Binding(
            get: { model.overlayStyle.backgroundOpacity },
            set: { newValue in
                model.updateOverlayStyle { style in
                    style.backgroundOpacity = newValue
                }
            }
        )
    }

    private var translatedFontBinding: Binding<Double> {
        Binding(
            get: { model.overlayStyle.translatedFontSize },
            set: { newValue in
                model.updateOverlayStyle { style in
                    style.translatedFontSize = newValue
                }
            }
        )
    }
}
