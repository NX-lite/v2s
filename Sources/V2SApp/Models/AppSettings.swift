import Foundation

struct AppSettings: Codable {
    var selectedSourceID: String?
    var inputLanguageID: String
    var outputLanguageID: String
    var overlayStyle: OverlayStyle

    static let `default` = AppSettings(
        selectedSourceID: nil,
        inputLanguageID: "en",
        outputLanguageID: "zh-Hans",
        overlayStyle: .default
    )
}
