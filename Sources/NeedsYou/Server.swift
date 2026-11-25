import Foundation
import NeedsYouShared

/// Unix domain socket in ~/Library/Application Support/Needs You (dir 0700,
/// socket 0600). Each connection is checked with getpeereid: only processes
/// of the same user get through.
final class Server {
    static let shared = Server()
    private var listenFD: Int32 = -1

    enum StartError: Error { case alreadyRunning, failed(String) }

    func start() throws {
        let dir = Wire.supportDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        chmod(dir.path, 0o700)
        let path = Wire.socketPath

        if let fd = UnixSocket.connect(path) { close(fd); throw StartError.alreadyRunning }
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.failed("socket") }
        var addr = UnixSocket.address(path)
        let oldMask = umask(0o177)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(oldMask)
        guard bound == 0 else { close(fd); throw StartError.failed("bind errno \(errno)") }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { close(fd); throw StartError.failed("listen") }
        listenFD = fd

        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
    }

    func stop() {
        if listenFD >= 0 { close(listenFD); unlink(Wire.socketPath) }
    }

    private func acceptLoop() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); continue }
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            Thread.detachNewThread { Self.serve(client) }
        }
    }

    private static func serve(_ fd: Int32) {
        guard let line = LineIO.readLine(fd: fd),
              let req = try? LineIO.decoder.decode(Request.self, from: line) else {
            var r = Response(status: "error"); r.error = "bad request"
            if let d = try? LineIO.encoder.encode(r) { _ = LineIO.writeLine(fd: fd, d) }
            close(fd); return
        }
        let alive: () -> Bool = {
            var b: UInt8 = 0
            let n = recv(fd, &b, 1, MSG_PEEK | MSG_DONTWAIT)
            if n == 0 { return false }
            if n < 0 && errno != EAGAIN && errno != EWOULDBLOCK { return false }
            return true
        }
        Task { @MainActor in
            let resp = await Conductor.shared.handle(req, clientAlive: alive)
            if let d = try? LineIO.encoder.encode(resp) { _ = LineIO.writeLine(fd: fd, d) }
            close(fd)
        }
    }
}
