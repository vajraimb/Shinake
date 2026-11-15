import Foundation
import ShinakeCore
import ShinakeRelay

let bind = ProcessInfo.processInfo.environment["SHINAKE_BIND"] ?? "127.0.0.1"
let port = Int(ProcessInfo.processInfo.environment["SHINAKE_PORT"] ?? "") ?? RoomProtocol.listenPort
let base = ProcessInfo.processInfo.environment["SHINAKE_PUBLIC_BASE"] ?? OnlineLinks.defaultPublicBase

let server: RelayServer
do {
    server = try RelayServer(bind: bind, port: port, publicBase: base)
} catch {
    fputs("shinake-server: \(error)\n", stderr)
    exit(1)
}
server.start()
fputs("shinake-server listening on \(bind):\(server.port)\n", stderr)
dispatchMain()
