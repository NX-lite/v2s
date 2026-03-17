import Foundation

struct OverlayStyle: Codable, Equatable {
    var targetDisplayID: String?
    var topInset: Double
    var widthRatio: Double
    var minWidth: Double
    var maxWidth: Double
    var backgroundOpacity: Double
    var translatedFontSize: Double
    var sourceFontSize: Double
    var clickThrough: Bool
    var translatedFirst: Bool

    static let `default` = OverlayStyle(
        targetDisplayID: nil,
        topInset: 12,
        widthRatio: 0.82,
        minWidth: 720,
        maxWidth: 1440,
        backgroundOpacity: 0.32,
        translatedFontSize: 24,
        sourceFontSize: 18,
        clickThrough: true,
        translatedFirst: true
    )
}
