import Foundation

@main struct RealtimeWebSocketTransportSmoke {
    static func main() async throws {
        guard let url = URL(string: "wss://example.invalid/realtime") else {
            preconditionFailure("test URL was invalid")
        }
        let task = URLSession.shared.webSocketTask(with: url)
        let connection = URLSessionRealtimeWebSocketConnection(task: task)
        await connection.close()

        do {
            try await connection.send(.text("synthetic"))
            preconditionFailure("closed connection accepted send")
        } catch RealtimeTransportError.closed {
        }

        do {
            _ = try await connection.receive()
            preconditionFailure("closed connection accepted receive")
        } catch RealtimeTransportError.closed {
        }
    }
}
