import Foundation
import Darwin
import DontSleepShared

protocol InstanceLocking: AnyObject {
    func acquire() -> Bool
    func release()
}

private func monotonicDeadline(after timeout: TimeInterval) -> UInt64 {
    DispatchTime.now().uptimeNanoseconds + UInt64(max(0, timeout) * 1_000_000_000)
}
private func deadlineHasExpired(_ deadline: UInt64) -> Bool {
    DispatchTime.now().uptimeNanoseconds >= deadline
}


private func setNonBlocking(_ descriptor: Int32) -> Bool {
    let flags = fcntl(descriptor, F_GETFL)
    return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
}

private func waitForSocket(_ descriptor: Int32, events: Int16, until deadline: UInt64) -> Bool {
    while !deadlineHasExpired(deadline) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { return false }
        let remaining = deadline - now
        var pollDescriptor = pollfd(fd: descriptor, events: events, revents: 0)
        let milliseconds = Int32(min(remaining / 1_000_000, UInt64(Int32.max)))
        guard !deadlineHasExpired(deadline) else { return false }
        let result = poll(&pollDescriptor, 1, milliseconds)
        if result > 0 { return pollDescriptor.revents & events != 0 }
        if result == 0 { return false }
        if errno != EINTR { return false }
    }
    return false
}

private func writeByte(_ byte: UInt8, to descriptor: Int32, until deadline: UInt64) -> Bool {
    var byte = byte
    while true {
        guard !deadlineHasExpired(deadline) else { return false }
        let result = write(descriptor, &byte, 1)
        if result == 1 { return true }
        if result < 0, errno == EAGAIN || errno == EWOULDBLOCK {
            guard waitForSocket(descriptor, events: Int16(POLLOUT), until: deadline) else { return false }
            continue
        }
        return false
    }
}

private func readByte(from descriptor: Int32, until deadline: UInt64) -> UInt8? {
    var byte: UInt8 = 0
    while true {
        guard !deadlineHasExpired(deadline) else { return nil }
        let result = read(descriptor, &byte, 1)
        if result == 1 { return byte }
        if result < 0, errno == EAGAIN || errno == EWOULDBLOCK {
            guard waitForSocket(descriptor, events: Int16(POLLIN), until: deadline) else { return nil }
            continue
        }
        return nil
    }
}
private let activationProtocolVersion: UInt8 = 1
private let activationEnabledTag: UInt8 = 1
private let activationAlreadyActiveTag: UInt8 = 2
private let activationFailedTag: UInt8 = 3

private func writeBytes(_ bytes: [UInt8], to descriptor: Int32, until deadline: UInt64) -> Bool {
    bytes.allSatisfy { writeByte($0, to: descriptor, until: deadline) }
}

private func readBytes(count: Int, from descriptor: Int32, until deadline: UInt64) -> [UInt8]? {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(count)
    for _ in 0..<count {
        guard let byte = readByte(from: descriptor, until: deadline) else { return nil }
        bytes.append(byte)
    }
    return bytes
}

private func encodeActivationReply(_ reply: ActivationReply) -> [UInt8] {
    switch reply {
    case .enabled:
        return [activationProtocolVersion, activationEnabledTag]
    case .alreadyActive:
        return [activationProtocolVersion, activationAlreadyActiveTag]
    case .failed(let code):
        let payload = UInt32(bitPattern: code).bigEndian
        return withUnsafeBytes(of: payload) { [activationProtocolVersion, activationFailedTag] + Array($0) }
    }
}

private func decodeActivationReply(from descriptor: Int32, until deadline: UInt64) -> ActivationReply? {
    guard let header = readBytes(count: 2, from: descriptor, until: deadline),
          header[0] == activationProtocolVersion else { return nil }
    switch header[1] {
    case activationEnabledTag:
        return .enabled
    case activationAlreadyActiveTag:
        return .alreadyActive
    case activationFailedTag:
        guard let payload = readBytes(count: MemoryLayout<UInt32>.size, from: descriptor, until: deadline) else { return nil }
        let code = payload.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        return .failed(Int32(bitPattern: code))
    default:
        return nil
    }
}

final class FileInstanceLock: InstanceLocking {
    private let url: URL
    private var descriptor: Int32 = -1

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        url = LaunchAgentContract.runLockURL(homeDirectory: homeDirectory)
    }

    func acquire() -> Bool {
        guard descriptor == -1 else { return true }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
        } catch { return false }
        descriptor = open(url.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return false }
        var lock = flock(l_start: 0, l_len: 0, l_pid: 0, l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET))
        guard fcntl(descriptor, F_SETLK, &lock) != -1 else { close(descriptor); descriptor = -1; return false }
        return true
    }

    func release() { guard descriptor >= 0 else { return }; _ = close(descriptor); descriptor = -1 }
    deinit { release() }
}

enum ActivationReply: Equatable { case enabled, alreadyActive, failed(Int32) }

protocol ActivationRequesting { func enableAndActivate(timeout: TimeInterval) -> ActivationReply? }

/// Same-user, monotonic-deadline request/reply client. Socket permissions and peer
/// credentials prevent another local user from requesting activation.
final class UnixSocketActivationRequester: ActivationRequesting {
    private let socketURL: URL
    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        socketURL = LaunchAgentContract.activationSocketURL(homeDirectory: homeDirectory)
    }

    func enableAndActivate(timeout: TimeInterval) -> ActivationReply? {
        let deadline = monotonicDeadline(after: timeout)
        guard !deadlineHasExpired(deadline) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        guard !deadlineHasExpired(deadline), setNonBlocking(fd) else { close(fd); return nil }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = socketURL.path.utf8CString
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        path.withUnsafeBytes { source in
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                destination.copyBytes(from: source)
            }
        }
        guard !deadlineHasExpired(deadline) else { return nil }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 || (result == -1 && errno == EINPROGRESS) else { return nil }
        if result != 0 {
            guard waitForSocket(fd, events: Int16(POLLOUT), until: deadline) else { return nil }
            var error: Int32 = 0
            guard !deadlineHasExpired(deadline) else { return nil }
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { return nil }
        }
        guard writeByte(1, to: fd, until: deadline) else { return nil }
        return decodeActivationReply(from: fd, until: deadline)
    }
}

final class ActivationListener {
    private var descriptor: Int32 = -1
    private var source: DispatchSourceRead?
    private let socketURL: URL
    private let handler: () -> ActivationReply
    private let requestTimeout: TimeInterval

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, requestTimeout: TimeInterval = 1, handler: @escaping () -> ActivationReply) {
        socketURL = LaunchAgentContract.activationSocketURL(homeDirectory: homeDirectory)
        self.requestTimeout = requestTimeout
        self.handler = handler
    }

    func start() -> Bool {
        guard descriptor == -1 else { return true }
        do {
            try FileManager.default.createDirectory(at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: socketURL.deletingLastPathComponent().path)
            try? FileManager.default.removeItem(at: socketURL)
        } catch { return false }
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0, setNonBlocking(descriptor) else { stop(); return false }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let path = socketURL.path.utf8CString
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { stop(); return false }
        path.withUnsafeBytes { source in
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                destination.copyBytes(from: source)
            }
        }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, listen(descriptor, 4) == 0 else { stop(); return false }
        guard chmod(socketURL.path, S_IRUSR | S_IWUSR) == 0 else { stop(); return false }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .global())
        source.setEventHandler { [weak self] in self?.acceptRequest() }
        source.resume(); self.source = source
        return true
    }

    func stop() { source?.cancel(); source = nil; if descriptor >= 0 { close(descriptor); descriptor = -1 }; try? FileManager.default.removeItem(at: socketURL) }
    deinit { stop() }

    private func acceptRequest() {
        while true {
            let deadline = monotonicDeadline(after: requestTimeout)
            guard !deadlineHasExpired(deadline) else { return }
            let client = accept(descriptor, nil, nil)
            if client < 0 {
                guard errno == EINTR else { return }
                continue
            }
            DispatchQueue.global().async { [handler, deadline] in
                defer { close(client) }
                guard !deadlineHasExpired(deadline), setNonBlocking(client) else { return }
                guard !deadlineHasExpired(deadline) else { return }
                var uid: uid_t = 0; var gid: gid_t = 0
                guard getpeereid(client, &uid, &gid) == 0, uid == geteuid() else { return }
                guard readByte(from: client, until: deadline) == 1 else { return }

                let completion = DispatchSemaphore(value: 0)
                var reply: ActivationReply?
                DispatchQueue.main.async {
                    guard !deadlineHasExpired(deadline) else {
                        completion.signal()
                        return
                    }
                    reply = handler()
                    completion.signal()
                }
                guard completion.wait(timeout: DispatchTime(uptimeNanoseconds: deadline)) == .success,
                      !deadlineHasExpired(deadline),
                      let reply else { return }

                _ = writeBytes(encodeActivationReply(reply), to: client, until: deadline)
            }
        }
    }
}

final class SingleInstanceCoordinator {
    enum Acquisition { case owner, forwarded(ActivationReply?), recoveryLoser }
    private let lock: InstanceLocking
    private let requester: ActivationRequesting

    init(lock: InstanceLocking = FileInstanceLock(), requester: ActivationRequesting = UnixSocketActivationRequester()) { self.lock = lock; self.requester = requester }
    func acquire(recovery: Bool) -> Acquisition { if lock.acquire() { return .owner }; return recovery ? .recoveryLoser : .forwarded(requester.enableAndActivate(timeout: 1)) }
    func release() { lock.release() }
}
