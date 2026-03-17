import Foundation

enum SessionState: String, Codable {
    case idle
    case running
    case error

    var displayName: String {
        switch self {
        case .idle:
            return "Idle"
        case .running:
            return "Running"
        case .error:
            return "Error"
        }
    }
}
