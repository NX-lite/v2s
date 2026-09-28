import Foundation

enum RealtimeSocketMessage: Equatable, Sendable {
    case text(String)
    case binary(Data)
}

enum RealtimeTransportError: Error, Equatable, Sendable {
    case connectionFailed
    case closed
    case unsupportedMessage
}

protocol RealtimeWebSocketConnection: Sendable {
    func send(_ message: RealtimeSocketMessage) async throws
    func receive() async throws -> RealtimeSocketMessage
    func close() async
}

protocol RealtimeWebSocketConnecting: Sendable {
    func connect(request: URLRequest) async throws -> any RealtimeWebSocketConnection
}

struct URLSessionRealtimeWebSocketConnector: RealtimeWebSocketConnecting {
    func connect(request: URLRequest) async throws -> any RealtimeWebSocketConnection {
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        return URLSessionRealtimeWebSocketConnection(task: task)
    }
}

actor URLSessionRealtimeWebSocketConnection: RealtimeWebSocketConnection {
    private let task: URLSessionWebSocketTask
    private var isClosed = false

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func send(_ message: RealtimeSocketMessage) async throws {
        guard !isClosed else { throw RealtimeTransportError.closed }
        do {
            switch message {
            case .text(let text):
                try await task.send(.string(text))
            case .binary(let data):
                try await task.send(.data(data))
            }
        } catch {
            throw RealtimeTransportError.connectionFailed
        }
    }

    func receive() async throws -> RealtimeSocketMessage {
        guard !isClosed else { throw RealtimeTransportError.closed }
        do {
            switch try await task.receive() {
            case .string(let text):
                return .text(text)
            case .data(let data):
                return .binary(data)
            @unknown default:
                throw RealtimeTransportError.unsupportedMessage
            }
        } catch let error as RealtimeTransportError {
            throw error
        } catch {
            throw RealtimeTransportError.connectionFailed
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        task.cancel(with: .goingAway, reason: nil)
    }
}
