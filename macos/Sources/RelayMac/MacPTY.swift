import Foundation
import RelayPTY
import Darwin

/// PTY bytes and bounded input are serialized away from the UI thread.
final class MacPTY {
    let processID: pid_t
    private let queue = DispatchQueue(label: "Relay.terminal.io")
    private let queueKey = DispatchSpecificKey<Bool>()
    private var fd: Int32
    private var pid: pid_t
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var process: DispatchSourceProcess?
    private var pending = Data()
    private var reading = false, readerSuspended = false, exitPending = false
    private let output: (Data, @escaping () -> Void) -> Void
    private let exited: () -> Void

    init(columns: Int, rows: Int, shell: String? = nil, home: String = NSHomeDirectory(),
         output: @escaping (Data, @escaping () -> Void) -> Void, exited: @escaping () -> Void) throws {
        self.output = output; self.exited = exited
        let loginShell = shell ?? getpwuid(getuid()).flatMap { $0.pointee.pw_shell }.map { String(cString: $0) } ?? "/bin/zsh"
        guard loginShell.hasPrefix("/"), access(loginShell, X_OK) == 0 else { throw CocoaError(.fileNoSuchFile) }
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"; environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Relay"; environment["PWD"] = home
        environment["HOME"] = home
        let strings = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") }
        defer { strings.forEach { free($0) } }
        var pointers = strings + [nil]
        var master: Int32 = -1
        let child = pointers.withUnsafeMutableBufferPointer { env in
            relay_pty_start(loginShell, home, env.baseAddress, Int32(columns), Int32(rows), &master)
        }
        guard child > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        fd = master; pid = child; processID = child
        queue.setSpecific(key: queueKey, value: true)
        let reader = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        reader.setEventHandler { [weak self] in self?.readAvailable() }
        self.reader = reader
        let process = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: queue)
        process.setEventHandler { [weak self] in
            guard let self else { return }
            self.exitPending = true; self.readAvailable()
        }
        self.process = process
        reader.resume(); process.resume()
    }

    @discardableResult func write(_ text: String) -> Bool {
        let data = Data(text.utf8)
        return queue.sync {
            guard fd >= 0, pending.count + data.count <= 1_048_576 else { return false }
            pending.append(data); flush(); return true
        }
    }
    func resize(columns: Int, rows: Int) {
        queue.async { [weak self] in
            guard let self, self.fd >= 0 else { return }
            _ = relay_pty_resize(self.fd, Int32(min(500, max(2, columns))), Int32(min(500, max(2, rows))))
        }
    }
    private func readAvailable() {
        guard fd >= 0, !reading else { return }
        var bytes = [UInt8](repeating: 0, count: 16_384)
        var batch = Data()
        var endOfFile = false
        for _ in 0..<4 {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 { batch.append(contentsOf: bytes.prefix(count)) }
            else if count < 0 && errno == EINTR { continue }
            else { endOfFile = count == 0 || errno == EIO; break }
        }
        guard !batch.isEmpty else {
            if exitPending { stop(); exited() }
            else if endOfFile && !readerSuspended { reader?.suspend(); readerSuspended = true }
            return
        }
        // Backpressure extends through xterm's write callback. A noisy child
        // cannot accumulate unbounded native callbacks or browser write buffers.
        reading = true
        if !readerSuspended { reader?.suspend(); readerSuspended = true }
        output(batch) { [weak self] in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self else { return }
                self.reading = false
                if self.readerSuspended { self.reader?.resume(); self.readerSuspended = false }
                if self.exitPending { self.readAvailable() }
            }
        }
    }
    private func flush() {
        guard fd >= 0 else { return }
        while !pending.isEmpty {
            let count = pending.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if count > 0 { pending.removeFirst(count) }
            else if count < 0 && errno == EINTR { continue }
            else { break }
        }
        if pending.isEmpty { writer?.cancel(); writer = nil }
        else if writer == nil {
            let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.flush() }
            writer = source; source.resume()
        }
    }
    private func stop() {
        if readerSuspended { reader?.resume(); readerSuspended = false }
        reader?.cancel(); reader = nil; writer?.cancel(); writer = nil
        process?.cancel(); process = nil
        if pid > 0 { relay_pty_stop(pid); pid = 0 }
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        pending.removeAll()
    }
    func close() {
        if DispatchQueue.getSpecific(key: queueKey) == true { stop() }
        else { queue.sync { stop() } }
    }
    deinit { close() }
}
