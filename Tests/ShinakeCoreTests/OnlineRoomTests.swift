import XCTest
#if canImport(ShinakeCore)
@testable import ShinakeCore
#else
@testable import Shinake
#endif

final class OnlineRoomTests: XCTestCase {
    func testRoomCodesAndInviteLinks() {
        XCTAssertFalse(RoomCode.isValid("000000"))
        XCTAssertFalse(RoomCode.isValid("12345"))
        XCTAssertFalse(RoomCode.isValid("12a456"))
        XCTAssertTrue(RoomCode.isValid("123456"))
        XCTAssertEqual(OnlineLinks.roomCode(from: URL(string: "https://vajra.one/shinake/join/123456")!), "123456")
        XCTAssertEqual(OnlineLinks.roomCode(from: URL(string: "shinake://join/654321")!), "654321")
        XCTAssertEqual(OnlineLinks.webSocketURL()?.absoluteString, "wss://vajra.one/shinake/ws")
        XCTAssertEqual(OnlineLinks.httpsJoin(code: "123456")?.absoluteString, "https://vajra.one/shinake/join/123456")
        XCTAssertEqual(OnlineLinks.appJoin(code: "123456")?.absoluteString, "shinake://join/123456")
        XCTAssertNil(OnlineLinks.roomCode(from: URL(string: "https://vajra.one/yuguan/join/123456")!))
    }

    func testCreateJoinRelayAndAFullRoom() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let hub = RoomHub(codes: ["246810"])
        let host = UUID()
        let guest = UUID()
        hub.open(host, at: now)
        let welcome = hub.receive(host, .hello(RoomHello(clientID: "1111111111111111", roomCode: nil)), ip: "203.0.113.4", at: now)
        guard case .welcome(let card) = welcome.first?.message else {
            return XCTFail("expected welcome")
        }
        XCTAssertTrue(card.host)
        XCTAssertEqual(card.roomCode, "246810")
        XCTAssertEqual(card.inviteURL, "https://vajra.one/shinake/join/246810")
        XCTAssertFalse(card.resumeToken.isEmpty)

        hub.open(guest, at: now)
        let joined = hub.receive(guest, .hello(RoomHello(clientID: "2222222222222222", roomCode: "246810")), ip: "203.0.113.5", at: now)
        XCTAssertEqual(joined.count, 2)
        guard case .welcome(let guestCard) = joined[0].message else { return XCTFail("guest welcome") }
        XCTAssertFalse(guestCard.host)
        XCTAssertEqual(joined[0].link, guest)
        guard case .peer(let peer) = joined[1].message else { return XCTFail("peer") }
        XCTAssertEqual(joined[1].link, host)
        XCTAssertEqual(peer.role, .joiner)
        XCTAssertTrue(peer.connected)

        let input = hub.receive(guest, .input(seq: 1, control: .screen(.left)), ip: "203.0.113.5", at: now)
        guard case .input(let seq, let control) = input.first?.message else { return XCTFail("input") }
        XCTAssertEqual(input.first?.link, host)
        XCTAssertEqual(seq, 1)
        XCTAssertEqual(control, .screen(.left))

        let snap = DuelMatch(seed: 3).snapshot()
        let forwarded = hub.receive(host, .snapshot(snap), ip: "203.0.113.4", at: now)
        guard case .snapshot(let got) = forwarded.first?.message else { return XCTFail("snapshot") }
        XCTAssertEqual(forwarded.first?.link, guest)
        XCTAssertEqual(got, snap)

        let extra = UUID()
        hub.open(extra, at: now)
        let full = hub.receive(extra, .hello(RoomHello(clientID: "3333333333333333", roomCode: "246810")), ip: "203.0.113.6", at: now)
        guard case .rejected(let reason) = full.first?.message else { return XCTFail("full") }
        XCTAssertEqual(reason, "房间满了")
    }

    func testGuestDropCanResumeForFiveSecondsAndHostDropEndsImmediately() {
        let now = Date(timeIntervalSince1970: 1_700_000_100)
        let hub = RoomHub(codes: ["135791"])
        let host = UUID()
        let guest = UUID()
        hub.open(host, at: now)
        _ = hub.receive(host, .hello(RoomHello(clientID: "1111111111111111")), ip: "198.51.100.1", at: now)
        hub.open(guest, at: now)
        let joined = hub.receive(guest, .hello(RoomHello(clientID: "2222222222222222", roomCode: "135791")), ip: "198.51.100.2", at: now)
        guard case .welcome(let card) = joined[0].message else { return XCTFail("welcome") }

        let left = hub.disconnect(guest, at: now.addingTimeInterval(1))
        guard case .peer(let gone) = left.first?.message else { return XCTFail("gone") }
        XCTAssertFalse(gone.connected)
        XCTAssertEqual(left.first?.link, host)

        let late = UUID()
        hub.open(late, at: now.addingTimeInterval(7))
        let tooLate = hub.receive(
            late,
            .hello(RoomHello(clientID: "2222222222222222", roomCode: "135791", resumeToken: card.resumeToken)),
            ip: "198.51.100.2",
            at: now.addingTimeInterval(7)
        )
        guard case .rejected(let lateReason) = tooLate.first?.message else { return XCTFail("late") }
        XCTAssertEqual(lateReason, "重连超时")

        let again = UUID()
        let earlyAt = now.addingTimeInterval(3)
        hub.open(again, at: earlyAt)
        let resumed = hub.receive(
            again,
            .hello(RoomHello(clientID: "2222222222222222", roomCode: "135791", resumeToken: card.resumeToken)),
            ip: "198.51.100.2",
            at: earlyAt
        )
        guard case .peer(let back) = resumed.last?.message else { return XCTFail("resume") }
        XCTAssertTrue(back.connected)
        XCTAssertEqual(resumed.last?.link, host)

        let ended = hub.disconnect(host, at: earlyAt.addingTimeInterval(1))
        guard case .ended(let reason) = ended.first?.message else { return XCTFail("ended") }
        XCTAssertEqual(reason, "hostLeft")
        XCTAssertEqual(ended.first?.link, again)
        XCTAssertEqual(hub.roomCount, 0)
    }

    func testExpiredCodeAndSilentHostAndCreateLimit() {
        let now = Date(timeIntervalSince1970: 1_700_000_500)
        let hub = RoomHub(codes: ["222333"], maxRooms: 2)
        let host = UUID()
        hub.open(host, at: now)
        _ = hub.receive(host, .hello(RoomHello(clientID: "1111111111111111")), ip: "192.0.2.8", at: now)
        let guest = UUID()
        hub.open(guest, at: now.addingTimeInterval(RoomProtocol.roomTTL + 1))
        let expired = hub.receive(
            guest,
            .hello(RoomHello(clientID: "2222222222222222", roomCode: "222333")),
            ip: "192.0.2.9",
            at: now.addingTimeInterval(RoomProtocol.roomTTL + 1)
        )
        guard case .rejected(let reason) = expired.first?.message else { return XCTFail("expired") }
        XCTAssertEqual(reason, "房间码已过期")

        let silent = hub.tick(at: now.addingTimeInterval(RoomProtocol.heartbeatTimeout))
        XCTAssertTrue(silent.isEmpty)
        XCTAssertEqual(hub.roomCount, 0)

        let limited = RoomHub(codes: Array(repeating: "444555", count: 8))
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<RoomProtocol.createPerMinute {
            let link = UUID()
            limited.open(link, at: stamp)
            let made = limited.receive(link, .hello(RoomHello(clientID: String(format: "44444444444444%02d", index))), ip: "192.0.2.10", at: stamp)
            guard case .welcome = made.first?.message else { return XCTFail("create \(index)") }
        }
        let blockedLink = UUID()
        limited.open(blockedLink, at: stamp)
        let blocked = limited.receive(blockedLink, .hello(RoomHello(clientID: "ffffffffffffffff")), ip: "192.0.2.10", at: stamp)
        guard case .rejected(let limitReason) = blocked.first?.message else { return XCTFail("limit") }
        XCTAssertEqual(limitReason, "创建太频繁")
    }
}
