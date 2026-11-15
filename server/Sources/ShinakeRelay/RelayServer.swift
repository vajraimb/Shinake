import Foundation
import ShinakeCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Local HTTP + WebSocket relay. Caddy terminates TLS. This process forwards
/// room messages and does not run a match.
public final class RelayServer {
    public let port: Int
    private let listenFD: Int32
    private let hub: RoomHub
    private let lock = NSLock()
    private var sockets: [UUID: Connection] = [:]
    private var acceptThread: Thread?
    private var tickThread: Thread?
    private var stopped = false

    public init(bind host: String = "127.0.0.1", port: Int = RoomProtocol.listenPort, publicBase: String = OnlineLinks.defaultPublicBase) throws {
        signal(SIGPIPE, SIG_IGN)
        self.hub = RoomHub(publicBase: publicBase)
        self.listenFD = try POSIX.listen(host: host, port: port)
        self.port = POSIX.boundPort(listenFD)
    }

    public func start() {
        acceptThread = Thread { [weak self] in self?.acceptLoop() }
        acceptThread?.start()
        tickThread = Thread { [weak self] in self?.tickLoop() }
        tickThread?.start()
    }

    public func stop() {
        stopped = true
        POSIX.shutdown(listenFD)
        POSIX.close(listenFD)
        lock.lock()
        let open = Array(sockets.values)
        lock.unlock()
        for conn in open {
            conn.markClosed()
            POSIX.shutdown(conn.fd)
        }
    }

    private func acceptLoop() {
        while !stopped {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { continue }
            Thread { [weak self] in self?.serve(fd) }.start()
        }
    }

    private func tickLoop() {
        while !stopped {
            Thread.sleep(forTimeInterval: 0.4)
            let now = Date()
            lock.lock()
            let deliveries = hub.tick(at: now)
            lock.unlock()
            deliver(deliveries)
        }
    }

    private func serve(_ fd: Int32) {
        var nodelay: Int32 = 1
        setsockopt(fd, Int32(IPPROTO_TCP), Int32(TCP_NODELAY), &nodelay, socklen_t(MemoryLayout<Int32>.size))
        let ip = POSIX.peerAddress(fd)
        defer { POSIX.close(fd) }
        guard let header = POSIX.readHeader(fd) else { return }
        guard let request = HTTPRequest(header) else {
            POSIX.writeAll(fd, HTTP.bytes(400, "text/plain", "bad request"))
            return
        }
        if request.upgrade && request.path == OnlineLinks.wsPath {
            guard let key = request.header("sec-websocket-key") else {
                POSIX.writeAll(fd, HTTP.bytes(400, "text/plain", "missing key"))
                return
            }
            POSIX.writeAll(fd, Data(WebSocket.handshake(key: key).utf8))
            let link = UUID()
            let conn = Connection(fd: fd)
            lock.lock()
            sockets[link] = conn
            hub.open(link, at: Date())
            lock.unlock()
            let forwarded = request.header("x-forwarded-for")
            let clientIP = forwarded?.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ip
            readFrames(conn, link: link, ip: clientIP.isEmpty ? ip : clientIP)
            lock.lock()
            sockets[link] = nil
            let left = hub.disconnect(link, at: Date())
            lock.unlock()
            deliver(left)
            return
        }
        POSIX.writeAll(fd, page(for: request))
    }

    private func readFrames(_ conn: Connection, link: UUID, ip: String) {
        while !conn.isClosed {
            guard let payload = WebSocket.readText(conn.fd) else { break }
            guard let message = try? JSONDecoder().decode(RoomClientMessage.self, from: Data(payload.utf8)) else {
                deliver([RoomDelivery(link: link, message: .rejected("消息看不懂"))])
                continue
            }
            lock.lock()
            let out = hub.receive(link, message, ip: ip, at: Date())
            lock.unlock()
            deliver(out)
        }
    }

    private func deliver(_ items: [RoomDelivery]) {
        for item in items {
            guard let body = try? JSONEncoder().encode(item.message) else { continue }
            let text = String(decoding: body, as: UTF8.self)
            lock.lock()
            let conn = sockets[item.link]
            lock.unlock()
            conn?.send(WebSocket.serverText(text))
        }
    }

    private func page(for request: HTTPRequest) -> Data {
        if request.path == "/healthz" {
            return HTTP.bytes(200, "text/plain; charset=utf-8", "ok\n")
        }
        if request.path == "/.well-known/apple-app-site-association" {
            return HTTP.bytes(200, "application/json", RoomAASA.json)
        }
        let weChat = request.header("user-agent")?.contains("MicroMessenger") == true
        if request.path == "/shinake/join" || request.path == "/shinake/join/" {
            return HTTP.bytes(200, "text/html; charset=utf-8", joinHTML(code: nil, weChat: weChat))
        }
        if request.path.hasPrefix(OnlineLinks.joinPrefix) {
            let code = String(request.path.dropFirst(OnlineLinks.joinPrefix.count))
            if RoomCode.isValid(code) {
                return HTTP.bytes(200, "text/html; charset=utf-8", joinHTML(code: code, weChat: weChat))
            }
        }
        return HTTP.bytes(404, "text/plain; charset=utf-8", "not found\n")
    }

    private func joinHTML(code: String?, weChat: Bool) -> String {
        let title = code.map { "食蛇房间 \($0)" } ?? "食蛇对战"
        let tip = weChat
            ? #"<p class="tip">点右上角 ··· 选择「在浏览器打开」</p>"#
            : ""
        let body: String
        if let code {
            let app = "shinake://join/\(code)"
            body = """
            <p class="code">\(code)</p>
            <p>把这 6 位房间码发给朋友，或让对方打开你分享的链接。</p>
            <p><a class="btn" href="\(app)">在食蛇中打开</a></p>
            <p class="sub">如果没有安装食蛇，先安装再打开此页。</p>
            """
        } else {
            body = "<p>向房主要 6 位房间码，或打开对方发来的链接。</p>"
        }
        return """
        <!DOCTYPE html>
        <html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(title)</title>
        <style>
        body{font-family:-apple-system,"PingFang SC",sans-serif;background:#070914;color:#f4f6f8;margin:0;padding:32px 20px;text-align:center}
        .code{font-size:48px;letter-spacing:8px;color:#c6f36b;margin:12px 0}
        a{color:#c6f36b}
        .btn{display:inline-block;margin-top:12px;padding:12px 22px;background:#c6f36b;color:#10140a;text-decoration:none;border-radius:12px;font-weight:600}
        .sub{color:#b7c0c8;font-size:14px}
        .tip{margin:0 auto 16px;max-width:28em;padding:14px 16px;background:#c6f36b;color:#10140a;border-radius:12px;font-weight:700}
        </style></head><body>
        \(tip)
        <h1>\(title)</h1>
        \(body)
        <p class="sub">只和你邀请的朋友同房。不保存昵称和地址。</p>
        </body></html>
        """
    }
}

final class Connection: @unchecked Sendable {
    let fd: Int32
    private let writeLock = NSLock()
    private var closed = false

    init(fd: Int32) { self.fd = fd }

    var isClosed: Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        return closed
    }

    func markClosed() {
        writeLock.lock()
        closed = true
        writeLock.unlock()
    }

    func send(_ data: Data) {
        writeLock.lock()
        let still = !closed
        writeLock.unlock()
        guard still else { return }
        POSIX.writeAll(fd, data)
    }
}

enum WebSocket {
    static func handshake(key: String) -> String {
        let accept = SHA1.webSocketAccept(key)
        return "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
    }

    static func serverText(_ text: String) -> Data {
        var frame = Data([0x81])
        let payload = Data(text.utf8)
        appendLength(payload.count, masked: false, to: &frame)
        frame.append(payload)
        return frame
    }

    static func clientText(_ text: String) -> Data {
        var frame = Data([0x81])
        let payload = [UInt8](text.utf8)
        appendLength(payload.count, masked: true, to: &frame)
        let mask: [UInt8] = [0x11, 0x22, 0x33, 0x44]
        frame.append(contentsOf: mask)
        for (index, byte) in payload.enumerated() {
            frame.append(byte ^ mask[index % 4])
        }
        return frame
    }

    static func readText(_ fd: Int32) -> String? {
        while true {
            guard let header = POSIX.readExact(fd, 2) else { return nil }
            let bytes = [UInt8](header)
            let opcode = bytes[0] & 0x0f
            let masked = bytes[1] & 0x80 != 0
            var length = Int(bytes[1] & 0x7f)
            if length == 126 {
                guard let extra = POSIX.readExact(fd, 2) else { return nil }
                let pair = [UInt8](extra)
                length = Int(pair[0]) << 8 | Int(pair[1])
            } else if length == 127 {
                guard let extra = POSIX.readExact(fd, 8) else { return nil }
                let wide = [UInt8](extra)
                var value = 0
                for byte in wide { value = (value << 8) | Int(byte) }
                length = value
            }
            if length < 0 || length > 1_000_000 { return nil }
            let mask: [UInt8]
            if masked {
                guard let key = POSIX.readExact(fd, 4) else { return nil }
                mask = [UInt8](key)
            } else {
                mask = [0, 0, 0, 0]
            }
            guard let payload = POSIX.readExact(fd, length) else { return nil }
            var body = [UInt8](payload)
            if masked {
                for index in body.indices { body[index] ^= mask[index % 4] }
            }
            if opcode == 0x8 { return nil }
            if opcode == 0x9 {
                var pong = Data([0x8A])
                appendLength(body.count, masked: false, to: &pong)
                pong.append(contentsOf: body)
                POSIX.writeAll(fd, pong)
                continue
            }
            if opcode == 0x1 {
                return String(decoding: body, as: UTF8.self)
            }
        }
    }

    private static func appendLength(_ length: Int, masked: Bool, to frame: inout Data) {
        let flag: UInt8 = masked ? 0x80 : 0
        if length < 126 {
            frame.append(flag | UInt8(length))
        } else if length < 65536 {
            frame.append(flag | 126)
            frame.append(UInt8((length >> 8) & 0xff))
            frame.append(UInt8(length & 0xff))
        } else {
            frame.append(flag | 127)
            var wide = length
            var bytes = [UInt8](repeating: 0, count: 8)
            for index in stride(from: 7, through: 0, by: -1) {
                bytes[index] = UInt8(wide & 0xff)
                wide >>= 8
            }
            frame.append(contentsOf: bytes)
        }
    }
}

struct HTTPRequest {
    var path: String
    var upgrade: Bool
    private var headers: [String: String]

    init?(_ raw: String) {
        let lines = raw.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let target = String(parts[1])
        path = target.split(separator: "?").first.map(String.init) ?? target
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where line.contains(":") {
            let pair = line.split(separator: ":", maxSplits: 1)
            headers[pair[0].trimmingCharacters(in: .whitespaces).lowercased()] = pair[1].trimmingCharacters(in: .whitespaces)
        }
        self.headers = headers
        upgrade = headers["upgrade"]?.lowercased() == "websocket"
    }

    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

enum HTTP {
    static func bytes(_ code: Int, _ type: String, _ body: String) -> Data {
        let payload = Data(body.utf8)
        let reason: String
        switch code {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        default: reason = "Error"
        }
        let head = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(payload.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        var data = Data(head.utf8)
        data.append(payload)
        return data
    }
}

enum POSIX {
    static func listen(host: String, port: Int) throws -> Int32 {
        let fd = socket(AF_INET, posixSocketType(SOCK_STREAM), 0)
        if fd < 0 { throw POSIXError(message: "socket") }
        var yes: Int32 = 1
        setsockopt(fd, Int32(SOL_SOCKET), Int32(SO_REUSEADDR), &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        if inet_pton(AF_INET, host, &addr.sin_addr) != 1 {
            close(fd)
            throw POSIXError(message: "bind address")
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if bound != 0 || systemListen(fd, 64) != 0 {
            systemClose(fd)
            throw POSIXError(message: "listen")
        }
        return fd
    }

    static func boundPort(_ fd: Int32) -> Int {
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let rc = withUnsafeMutablePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        if rc != 0 { return 0 }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    static func peerAddress(_ fd: Int32) -> String {
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let rc = withUnsafeMutablePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &len) }
        }
        if rc != 0 { return "local" }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var copy = addr.sin_addr
        guard inet_ntop(AF_INET, &copy, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return "local" }
        return String(cString: buffer)
    }

    static func readHeader(_ fd: Int32) -> String? {
        var data = Data()
        var byte = [UInt8](repeating: 0, count: 1)
        while data.range(of: Data("\r\n\r\n".utf8)) == nil {
            if data.count > 8192 { return nil }
            let n = read(fd, &byte, 1)
            if n <= 0 { return nil }
            data.append(byte[0])
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func readExact(_ fd: Int32, _ count: Int) -> Data? {
        if count == 0 { return Data() }
        var data = Data()
        var scratch = [UInt8](repeating: 0, count: 4096)
        while data.count < count {
            let want = min(4096, count - data.count)
            let n = read(fd, &scratch, want)
            if n <= 0 { return nil }
            data.append(contentsOf: scratch.prefix(n))
        }
        return data
    }

    static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let n = write(fd, base.advanced(by: sent), data.count - sent)
                if n <= 0 { return }
                sent += n
            }
        }
    }

    static func shutdown(_ fd: Int32) {
        _ = systemShutdown(fd, Int32(SHUT_RDWR))
    }

    static func close(_ fd: Int32) {
        systemClose(fd)
    }
}

/// glibc imports `SOCK_STREAM` as an enum. musl and Darwin import it as `Int32`.
func posixSocketType(_ type: Int32) -> Int32 { type }

func posixSocketType<T: RawRepresentable>(_ type: T) -> Int32 where T.RawValue: BinaryInteger {
    Int32(type.rawValue)
}

private func systemListen(_ fd: Int32, _ backlog: Int32) -> Int32 { listen(fd, backlog) }
private func systemShutdown(_ fd: Int32, _ how: Int32) -> Int32 { shutdown(fd, how) }
private func systemClose(_ fd: Int32) { _ = close(fd) }

struct POSIXError: Error { var message: String }
