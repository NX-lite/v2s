import Foundation

struct CorrectionSettings: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var apiKey: String
    var baseURL: String
    var model: String
    var disabledSourceIDs: [String] {
        didSet {
            disabledSourceIDs = Self.normalized(disabledSourceIDs)
        }
    }
    var isolatedContextSourceIDs: [String] {
        didSet {
            isolatedContextSourceIDs = Self.normalized(isolatedContextSourceIDs)
        }
    }

    static let `default` = Self(
        isEnabled: false,
        apiKey: "",
        baseURL: "https://api.openai.com/v1",
        model: "gpt-4o",
        disabledSourceIDs: [],
        isolatedContextSourceIDs: []
    )

    func isEnabled(for sourceID: String) -> Bool {
        isEnabled && !disabledSourceIDs.contains(sourceID)
    }

    func usesIsolatedContext(for sourceID: String) -> Bool {
        isolatedContextSourceIDs.contains(sourceID)
    }

    private static func normalized(_ values: [String]) -> [String] {
        Array(Set(values)).sorted()
    }
}

extension CorrectionSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? Self.default.isEnabled
        apiKey = (try? c.decodeIfPresent(String.self, forKey: .apiKey)) ?? Self.default.apiKey
        baseURL = (try? c.decodeIfPresent(String.self, forKey: .baseURL)) ?? Self.default.baseURL
        model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? Self.default.model
        disabledSourceIDs = Self.normalized(
            (try? c.decodeIfPresent([String].self, forKey: .disabledSourceIDs)) ?? []
        )
        isolatedContextSourceIDs = Self.normalized(
            (try? c.decodeIfPresent([String].self, forKey: .isolatedContextSourceIDs)) ?? []
        )
    }
}
