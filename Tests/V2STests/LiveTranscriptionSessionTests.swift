import Foundation
import Testing
@testable import v2s

@Suite struct LiveTranscriptionSessionTests {
    @Test func legacyRecognitionErrorDispositionIgnoresCancellationErrors() {
        #expect(disposition(code: 216) == .ignore)
        #expect(disposition(code: 301) == .ignore)
    }

    @Test func legacyRecognitionErrorDispositionRestartsAfterSilence() {
        #expect(disposition(code: 1110) == .restartImmediately)
    }

    @Test func legacyRecognitionErrorDispositionStopsAfterServerQuotaError() {
        #expect(
            disposition(
                code: 203,
                message: "Quota limit reached for resource: speech_api, actor_type: user"
            ) == .stopAndSurface
        )
    }

    // Code 203 also covers transient faults that a restart clears, so the code alone
    // must not end the session.
    @Test func legacyRecognitionErrorDispositionRetriesNonQuotaCode203() {
        #expect(disposition(code: 203, message: "Retry") == .retryWithBackoff)
        #expect(disposition(code: 203, message: "Corrupt") == .retryWithBackoff)
    }

    @Test func legacyRecognitionErrorDispositionStopsOnQuotaRegardlessOfCode() {
        #expect(
            disposition(code: 1700, message: "Quota limit reached for resource: speech_api") == .stopAndSurface
        )
    }

    @Test func legacyRecognitionErrorDispositionBacksOffOtherErrors() {
        #expect(disposition(code: 999) == .retryWithBackoff)
        #expect(
            LiveTranscriptionSession.legacyRecognitionErrorDisposition(
                domain: NSURLErrorDomain,
                code: NSURLErrorNotConnectedToInternet
            ) == .retryWithBackoff
        )
    }

    // A cancellation code from another domain is a real failure, not our own teardown.
    @Test func legacyRecognitionErrorDispositionDoesNotIgnoreForeignDomains() {
        #expect(
            LiveTranscriptionSession.legacyRecognitionErrorDisposition(
                domain: NSURLErrorDomain,
                code: 216
            ) == .retryWithBackoff
        )
    }

    private func disposition(
        code: Int,
        message: String = ""
    ) -> LiveTranscriptionSession.LegacyRecognitionErrorDisposition {
        LiveTranscriptionSession.legacyRecognitionErrorDisposition(
            domain: "kAFAssistantErrorDomain",
            code: code,
            message: message
        )
    }
}
