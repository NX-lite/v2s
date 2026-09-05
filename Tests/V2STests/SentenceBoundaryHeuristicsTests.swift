import Foundation
import Testing
@testable import v2s

@Suite struct SentenceBoundaryHeuristicsTests {
    @Test func sentenceRangesKeepSingleLetterNameInitialAttached() {
        let text = "Defense Secretary P. Texeth, with a warning to Iran, told troops about the ceasefire."
        let ranges = SentenceBoundaryHeuristics.sentenceRanges(in: text as NSString)

        #expect(ranges.count == 1)
        #expect((text as NSString).substring(with: ranges[0]) == text)
    }

    @Test func sentenceRangesKeepTitleAndSurnameAttached() {
        let text = "Sen. Warner said the vote would proceed. Markets reacted later."
        let ranges = SentenceBoundaryHeuristics.sentenceRanges(in: text as NSString)
        let sentences = ranges.map {
            (text as NSString).substring(with: $0).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        #expect(sentences.count == 2)
        #expect(sentences[0] == "Sen. Warner said the vote would proceed.")
        #expect(sentences[1] == "Markets reacted later.")
    }

    @Test func sentenceRangesKeepInitialismAndFollowingWordTogether() {
        let text = "The U.S. military responded quickly."
        let ranges = SentenceBoundaryHeuristics.sentenceRanges(in: text as NSString)

        #expect(ranges.count == 1)
        #expect((text as NSString).substring(with: ranges[0]) == text)
    }

    @Test func likelySentenceTerminatorRejectsDanglingNameInitial() {
        #expect(!SentenceBoundaryHeuristics.endsWithLikelySentenceTerminator(in: "Defense Secretary P."))
    }

    @Test func likelySentenceTerminatorStillAcceptsRealSentenceEnd() {
        #expect(SentenceBoundaryHeuristics.endsWithLikelySentenceTerminator(in: "This is the end."))
    }
}
