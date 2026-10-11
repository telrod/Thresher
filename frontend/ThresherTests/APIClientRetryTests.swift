//
//  APIClientRetryTests.swift
//  ThresherTests
//
//  The client retries a GET refused at connect (-1004), and nothing else.
//  Driven through a real URLSession with a stub protocol, so the retry is
//  exercised where it lives — in the client — rather than in a protocol fake.
//
//  A refused connect never reached the server, so a GET is safe to resend. A
//  write is not retried even then: the caller sees the failure and decides.
//

import XCTest
@testable import Thresher

private final class RefusingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _refuseFirst = 0
    nonisolated(unsafe) private static var _attempts: [String] = []

    static func reset(refuseFirst: Int) {
        lock.withLock { _refuseFirst = refuseFirst; _attempts = [] }
    }
    static var attempts: [String] { lock.withLock { _attempts } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let refused: Bool = Self.lock.withLock {
            Self._attempts.append(request.httpMethod ?? "GET")
            return Self._attempts.count <= Self._refuseFirst
        }
        if refused {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"accounts":["a@example.com"]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class APIClientRetryTests: XCTestCase {

    private func client() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RefusingURLProtocol.self]
        return APIClient(baseURL: URL(string: "http://localhost:8765")!,
                         session: URLSession(configuration: config))
    }

    func test_GET_refusedTwice_succeedsOnTheThirdAttempt() async throws {
        RefusingURLProtocol.reset(refuseFirst: 2)

        let accounts = try await client().listAccounts()

        XCTAssertEqual(accounts, ["a@example.com"])
        XCTAssertEqual(RefusingURLProtocol.attempts, ["GET", "GET", "GET"])
    }

    func test_GET_givesUpAfterThreeAttempts() async {
        RefusingURLProtocol.reset(refuseFirst: .max)

        do {
            _ = try await client().listAccounts()
            XCTFail("a backend that never answers must still surface an error")
        } catch {
            guard case APIError.transport = error else {
                return XCTFail("expected a transport error, got \(error)")
            }
        }
        XCTAssertEqual(RefusingURLProtocol.attempts.count, 3)
    }

    func test_writes_areNeverRetried() async {
        RefusingURLProtocol.reset(refuseFirst: .max)
        let api = client()

        _ = try? await api.setPreference(key: "k", value: "v")         // PUT
        _ = try? await api.verifyAccount("a@example.com")              // POST
        try? await api.disconnectAccount("a@example.com")              // DELETE

        XCTAssertEqual(RefusingURLProtocol.attempts, ["PUT", "POST", "DELETE"])
    }
}
