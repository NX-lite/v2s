import Foundation
import Testing
@testable import v2s

@Suite struct GlossaryServiceTests {
    private let service = GlossaryService()

    @Test func emptyGlossaryReturnsTextUnchanged() {
        #expect(service.apply(to: "He said AI wins", glossary: [:]) == "He said AI wins")
    }

    @Test func replacesStandaloneLatinTerm() {
        let result = service.apply(to: "He said AI wins", glossary: ["AI": "人工智能"])
        #expect(result == "He said 人工智能 wins")
    }

    @Test func doesNotReplaceLatinTermInsideAnotherWord() {
        let result = service.apply(to: "They repaired the airfield", glossary: ["AI": "人工智能"])
        #expect(result == "They repaired the airfield")
    }

    @Test func doesNotReplaceLatinTermSuffixInsideAnotherWord() {
        let result = service.apply(to: "OpenAI released a model", glossary: ["AI": "人工智能"])
        #expect(result == "OpenAI released a model")
    }

    @Test func replacesLatinTermAdjacentToCJKCharacters() {
        let result = service.apply(to: "使用AI模型", glossary: ["AI": "人工智能"])
        #expect(result == "使用人工智能模型")
    }

    @Test func replacesLatinTermAtStringBoundariesAndBeforePunctuation() {
        let result = service.apply(to: "AI is the future. I love AI.", glossary: ["AI": "人工智能"])
        #expect(result == "人工智能 is the future. I love 人工智能.")
    }

    @Test func matchesCaseInsensitively() {
        let result = service.apply(to: "ai everywhere", glossary: ["AI": "人工智能"])
        #expect(result == "人工智能 everywhere")
    }

    @Test func longestEntryWinsOverShorterOverlap() {
        let result = service.apply(
            to: "I love New York",
            glossary: ["New York": "纽约", "York": "约克"]
        )
        #expect(result == "I love 纽约")
    }

    @Test func replacesCJKTermWithoutWordBoundaries() {
        let result = service.apply(to: "这个模型很好", glossary: ["模型": "model"])
        #expect(result == "这个model很好")
    }

    @Test func digitEdgedTermRespectsBoundaries() {
        let glossary = ["5G": "五代网络"]
        #expect(service.apply(to: "The 25G link", glossary: glossary) == "The 25G link")
        #expect(service.apply(to: "用5G上网", glossary: glossary) == "用五代网络上网")
    }

    @Test func accentedLatinTermRespectsBoundaries() {
        let glossary = ["café": "咖啡馆"]
        #expect(service.apply(to: "meet at the café now", glossary: glossary) == "meet at the 咖啡馆 now")
        #expect(service.apply(to: "cafés stay open", glossary: glossary) == "cafés stay open")
    }

    @Test func nonLatinTermsRespectBoundaries() {
        #expect(service.apply(to: "протестирование продолжается", glossary: ["тест": "test"]) == "протестирование продолжается")
        #expect(service.apply(to: "καφές είναι έτοιμος", glossary: ["καφ": "coffee"]) == "καφές είναι έτοιμος")
        #expect(service.apply(to: "وسلامة الجميع", glossary: ["سلام": "peace"]) == "وسلامة الجميع")
    }
}
