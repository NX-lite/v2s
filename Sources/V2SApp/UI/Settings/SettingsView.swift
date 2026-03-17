import Foundation
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            generalSection
            sourceSection
            languageSection
            overlaySection
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(minWidth: 720, minHeight: 520)
    }

    private var generalSection: some View {
        Section("General") {
            row(title: "Session State", value: model.sessionBadgeText)
            row(title: "Status", value: model.statusMessage)

            HStack {
                Button(model.sessionButtonTitle) {
                    model.toggleSession()
                }
                .buttonStyle(.borderedProminent)

                Button("Show Subtitle Preview") {
                    model.showOverlayPreview()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var sourceSection: some View {
        Section("Input Source") {
            Picker("Selected Source", selection: selectedSourceBinding) {
                if model.allSources.isEmpty {
                    Text("No sources detected").tag("")
                } else {
                    ForEach(model.allSources) { source in
                        Text("\(source.category.displayName) · \(source.name)").tag(source.id)
                    }
                }
            }
            .pickerStyle(.menu)

            Button("Refresh Sources") {
                model.refreshSources()
            }
            .buttonStyle(.bordered)
        }
    }

    private var languageSection: some View {
        Section("Languages") {
            Picker("Input Language", selection: inputLanguageBinding) {
                ForEach(LanguageCatalog.common) { option in
                    Text(option.displayName).tag(option.id)
                }
            }

            Picker("Subtitle Language", selection: outputLanguageBinding) {
                ForEach(LanguageCatalog.common) { option in
                    Text(option.displayName).tag(option.id)
                }
            }
        }
    }

    private var overlaySection: some View {
        Section("Subtitle Overlay") {
            HStack {
                Toggle("Click-through", isOn: clickThroughBinding)
                Toggle("Translated Text First", isOn: translatedFirstBinding)
            }

            LabeledSlider(
                title: "Top Inset",
                value: topInsetBinding,
                range: 0 ... 48,
                precision: 0
            )

            LabeledSlider(
                title: "Width Ratio",
                value: widthRatioBinding,
                range: 0.50 ... 0.95,
                precision: 2
            )

            LabeledSlider(
                title: "Background Opacity",
                value: backgroundOpacityBinding,
                range: 0.16 ... 0.72,
                precision: 2
            )

            LabeledSlider(
                title: "Translated Font",
                value: translatedFontBinding,
                range: 16 ... 34,
                precision: 0
            )

            LabeledSlider(
                title: "Source Font",
                value: sourceFontBinding,
                range: 14 ... 28,
                precision: 0
            )
        }
    }

    private var selectedSourceBinding: Binding<String> {
        Binding(
            get: { model.selectedSourceID ?? "" },
            set: { model.selectedSourceID = $0.isEmpty ? nil : $0 }
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

    private var clickThroughBinding: Binding<Bool> {
        overlayBinding(\.clickThrough)
    }

    private var translatedFirstBinding: Binding<Bool> {
        overlayBinding(\.translatedFirst)
    }

    private var topInsetBinding: Binding<Double> {
        overlayBinding(\.topInset)
    }

    private var widthRatioBinding: Binding<Double> {
        overlayBinding(\.widthRatio)
    }

    private var backgroundOpacityBinding: Binding<Double> {
        overlayBinding(\.backgroundOpacity)
    }

    private var translatedFontBinding: Binding<Double> {
        overlayBinding(\.translatedFontSize)
    }

    private var sourceFontBinding: Binding<Double> {
        overlayBinding(\.sourceFontSize)
    }

    private func overlayBinding<Value>(_ keyPath: WritableKeyPath<OverlayStyle, Value>) -> Binding<Value> {
        Binding(
            get: { model.overlayStyle[keyPath: keyPath] },
            set: { newValue in
                model.updateOverlayStyle { style in
                    style[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func row(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}

private struct LabeledSlider: View {
    let title: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let precision: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(formattedValue)
                    .foregroundStyle(.secondary)
            }

            Slider(value: value, in: range)
        }
    }

    private var formattedValue: String {
        String(format: "%.\(precision)f", value.wrappedValue)
    }
}
