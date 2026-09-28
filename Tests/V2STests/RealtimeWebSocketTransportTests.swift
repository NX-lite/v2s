import Foundation
import Testing
@testable import v2s

@Suite struct RealtimeWebSocketTransportTests {
    @Test func closedProductionConnectionRejectsFurtherTrafficWithoutNetwork() async throws {
        let url = try #require(URL(string: "wss://example.invalid/realtime"))
        let task = URLSession.shared.webSocketTask(with: url)
        let connection = URLSessionRealtimeWebSocketConnection(task: task)

        await connection.close()
        await #expect(throws: RealtimeTransportError.closed) {
            try await connection.send(.text("synthetic"))
        }
        await #expect(throws: RealtimeTransportError.closed) {
            try await connection.receive()
        }
    }
}
