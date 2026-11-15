import Foundation
import XCTest
import ShinakeCore
@testable import ShinakeRelay
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class RelayTests: XCTestCase {
    func testWebSocketAcceptMatchesTheRFCVector() {
        XCTAssertEqual(SHA1.webSocketAccept("dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
        XCTAssertEqual(hex(SHA1.digest(Data())), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
    }

    func testStaticAASAKeepsYuguanAndAddsShinake() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("deploy/apple-app-site-association")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(
            text.trimmingCharacters(in: .whitespacesAndNewlines),
            RoomAASA.json.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        XCTAssertTrue(text.contains("A5VCS5XD6R.one.vajra.yuguan"))
        XCTAssertTrue(text.contains("A5VCS5XD6R.one.vajra.shinake"))
        XCTAssertTrue(text.contains("/yuguan/join/*"))
        XCTAssertTrue(text.contains("/shinake/join/*"))
        XCTAssertTrue(text.contains("friend room invite"))
    }

    func testRelayCreateJoinSnapshotAndBothDisconnects() throws {
        let server = try RelayServer(bind: "127.0.0.1", port: 0, publicBase: "https://vajra.one")
        server.start()
        defer { server.stop() }

        let health = try http("127.0.0.1", server.port, "GET /healthz HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        XCTAssertTrue(health.contains("\r\nok\n") || health.hasSuffix("ok\n"))

        let aasa = try http("127.0.0.1", server.port, "GET /.well-known/apple-app-site-association HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        XCTAssertTrue(aasa.contains("A5VCS5XD6R.one.vajra.yuguan"))
        XCTAssertTrue(aasa.contains("A5VCS5XD6R.one.vajra.shinake"))
        XCTAssertTrue(aasa.contains("/yuguan/join/*"))
        XCTAssertTrue(aasa.contains("/shinake/join/*"))

        let page = try http(
            "127.0.0.1",
            server.port,
            "GET /shinake/join/246810 HTTP/1.1\r\nHost: localhost\r\nUser-Agent: MicroMessenger\r\nConnection: close\r\n\r\n"
        )
        XCTAssertTrue(page.contains("shinake://join/246810"))
        XCTAssertTrue(page.contains("在浏览器打开"))
        XCTAssertFalse(page.contains("testflight.apple.com"))

        let host = try SocketClient(port: server.port)
        try host.sendHello(RoomHello(clientID: "1111111111111111"))
        let welcome = try host.next()
        guard case .welcome(let card) = welcome else {
            return XCTFail("welcome \(welcome)")
        }
        XCTAssertTrue(card.host)
        XCTAssertEqual(card.inviteURL, "https://vajra.one/shinake/join/\(card.roomCode)")

        let guest = try SocketClient(port: server.port)
        try guest.sendHello(RoomHello(clientID: "2222222222222222", roomCode: card.roomCode))
        guard case .welcome(let guestCard) = try guest.next() else { return XCTFail("guest welcome") }
        XCTAssertFalse(guestCard.host)
        guard case .peer(let joined) = try host.next() else { return XCTFail("peer") }
        XCTAssertTrue(joined.connected)
        XCTAssertEqual(joined.role, .joiner)

        try guest.send(.input(seq: 4, control: .screen(.left)))
        guard case .input(let seq, let control) = try host.next() else { return XCTFail("input") }
        XCTAssertEqual(seq, 4)
        XCTAssertEqual(control, .screen(.left))

        let snap = DuelMatch(seed: 9).snapshot()
        try host.send(.snapshot(snap))
        guard case .snapshot(let got) = try guest.next() else { return XCTFail("snapshot") }
        XCTAssertEqual(got, snap)

        let extra = try SocketClient(port: server.port)
        try extra.sendHello(RoomHello(clientID: "3333333333333333", roomCode: card.roomCode))
        guard case .rejected(let full) = try extra.next() else { return XCTFail("full") }
        XCTAssertEqual(full, "房间满了")
        extra.close()

        guest.close()
        guard case .peer(let gone) = try host.next() else { return XCTFail("guest drop") }
        XCTAssertFalse(gone.connected)
        host.close()

        let host2 = try SocketClient(port: server.port)
        try host2.sendHello(RoomHello(clientID: "aaaaaaaaaaaaaaaa"))
        guard case .welcome(let second) = try host2.next() else { return XCTFail("second room") }
        let guest2 = try SocketClient(port: server.port)
        try guest2.sendHello(RoomHello(clientID: "bbbbbbbbbbbbbbbb", roomCode: second.roomCode))
        guard case .welcome = try guest2.next() else { return XCTFail("second guest") }
        _ = try host2.next()
        host2.close()
        guard case .ended(let reason) = try guest2.next() else { return XCTFail("host drop") }
        XCTAssertEqual(reason, "hostLeft")
        guest2.close()
    }
}

private func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

private func http(_ host: String, _ port: Int, _ request: String) throws -> String {
    let fd = try connectTCP(port)
    defer { POSIX.close(fd) }
    POSIX.writeAll(fd, Data(request.utf8))
    var data = Data()
    var scratch = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &scratch, scratch.count)
        if n <= 0 { break }
        data.append(contentsOf: scratch.prefix(n))
    }
    return String(decoding: data, as: UTF8.self)
}

private final class SocketClient {
    let fd: Int32

    init(port: Int) throws {
        fd = try connectTCP(port)
        let key = "dGhlIHNhbXBsZSBub25jZQ=="
        let request = "GET /shinake/ws HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        POSIX.writeAll(fd, Data(request.utf8))
        guard let header = POSIX.readHeader(fd), header.contains("101") else {
            POSIX.close(fd)
            throw TestSocketError("handshake")
        }
    }

    func sendHello(_ hello: RoomHello) throws {
        try send(.hello(hello))
    }

    func send(_ message: RoomClientMessage) throws {
        let data = try JSONEncoder().encode(message)
        let text = String(decoding: data, as: UTF8.self)
        POSIX.writeAll(fd, WebSocket.clientText(text))
    }

    func next() throws -> RoomServerMessage {
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&poller, 1, 3000)
        if ready <= 0 { throw TestSocketError("timeout") }
        guard let text = WebSocket.readText(fd), let data = text.data(using: .utf8) else {
            throw TestSocketError("frame")
        }
        return try JSONDecoder().decode(RoomServerMessage.self, from: data)
    }

    func close() {
        POSIX.shutdown(fd)
        POSIX.close(fd)
    }
}

private func connectTCP(_ port: Int) throws -> Int32 {
    let deadline = Date().addingTimeInterval(2)
    var reason = "connect"
    while Date() < deadline {
        let fd = socket(AF_INET, posixStream, 0)
        if fd < 0 { throw TestSocketError("socket") }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        _ = inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc == 0 { return fd }
        reason = String(cString: strerror(errno))
        POSIX.close(fd)
        Thread.sleep(forTimeInterval: 0.02)
    }
    throw TestSocketError(reason)
}

private struct TestSocketError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}
