import Foundation

enum InputSourceCategory: String, CaseIterable, Codable {
    case application
    case microphone

    var displayName: String {
        switch self {
        case .application:
            return "Application"
        case .microphone:
            return "Microphone"
        }
    }
}

struct InputSource: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let detail: String
    let category: InputSourceCategory

    static let preview = InputSource(
        id: "preview",
        name: "Preview Source",
        detail: "preview",
        category: .microphone
    )
}
