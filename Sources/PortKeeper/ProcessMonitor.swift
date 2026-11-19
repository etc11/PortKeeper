import Foundation
import Darwin

struct Listener: Equatable, Sendable {
    let pid: Int32
    let command: String
    let uid: UInt32
    var addresses: [String]

    var ports: [Int] {
        Array(Set(addresses.compactMap { Int($0.split(separator: ":").last ?? "") })).sorted()
    }
}

struct ProcessIdentity: Hashable, Sendable {
    let pid: Int32
    let uid: UInt32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
}

struct PortProcess: Identifiable, Sendable {
    var id: Int32 { listener.pid }
    let listener: Listener
    let identity: ProcessIdentity?
    let residentBytes: UInt64?
    let executable: String?
    let protectionReason: String?
}

enum MonitorError: LocalizedError {
    case discovery(String), changed, forbidden, protectedProcess(String), signalFailed(String)

    var errorDescription: String? {
        switch self {
        case .discovery(let message): "Couldn’t refresh ports: \(message)"
        case .changed: "This process has exited or changed. Refresh and try again."
        case .forbidden: "Only processes owned by your account can be stopped."
        case .protectedProcess(let reason): "Protected process: \(reason)"
        case .signalFailed(let message): "Couldn’t stop process: \(message)"
        }
    }
}

enum ProcessMonitor {
    // lsof field output avoids relying on column widths or truncated process names.
    static func parse(_ output: String) -> [Listener] {
        var result: [Listener] = []
        var pid: Int32?
        var command = ""
        var uid: UInt32?
        var addresses: [String] = []
        func flush() {
            if let pid, let uid, !addresses.isEmpty {
                result.append(Listener(pid: pid, command: command, uid: uid,
                                       addresses: Array(Set(addresses)).sorted()))
            }
        }
        for line in output.split(separator: "\n") {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            switch field {
            case "p":
                flush()
                pid = Int32(value); command = ""; uid = nil; addresses = []
            case "c": command = value
            case "u": uid = UInt32(value)
            case "n":
                if let port = Int(value.split(separator: ":").last ?? ""), (1...65535).contains(port) {
                    addresses.append(value)
                }
            default: break
            }
        }
        flush()
        return result
    }

    static func identity(for pid: Int32) -> ProcessIdentity? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return ProcessIdentity(pid: pid, uid: info.pbi_uid,
                               startSeconds: info.pbi_start_tvsec,
                               startMicroseconds: info.pbi_start_tvusec)
    }

    static func executablePath(for pid: Int32) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is a C expression macro Swift cannot import.
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let pathLength = proc_pidpath(pid, &path, UInt32(path.count))
        return pathLength > 0
            ? String(decoding: path.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            : nil
    }

    static func snapshot(_ listener: Listener) -> PortProcess {
        let before = identity(for: listener.pid)
        var task = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let valid = proc_pidinfo(listener.pid, PROC_PIDTASKINFO, 0, &task, size) == size
        let executable = executablePath(for: listener.pid)
        let protection = ProcessProtection.liveReason(identity: before, executable: executable)
        let after = identity(for: listener.pid)
        let stable = before != nil && before == after && before?.uid == listener.uid
        return PortProcess(listener: listener, identity: stable ? before : nil,
                           residentBytes: stable && valid ? task.pti_resident_size : nil,
                           executable: stable ? executable : nil,
                           protectionReason: stable ? protection : "Process identity could not be verified.")
    }

    static func scan() throws -> [PortProcess] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcun"]
        let output = Pipe()
        process.standardOutput = output
        // lsof may warn about inaccessible volumes; do not mix warnings with its data.
        process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationReason == .exit,
              process.terminationStatus == 0 || (process.terminationStatus == 1 && data.isEmpty) else {
            throw MonitorError.discovery("port discovery failed or timed out")
        }
        return parse(String(decoding: data, as: UTF8.self)).map(snapshot)
    }

    static func stop(_ expected: ProcessIdentity, force: Bool) throws {
        guard expected.pid > 1, expected.pid != getpid(), expected.uid == getuid() else {
            throw MonitorError.forbidden
        }
        guard identity(for: expected.pid) == expected else { throw MonitorError.changed }
        let executable = executablePath(for: expected.pid)
        if let reason = ProcessProtection.liveReason(identity: expected, executable: executable) {
            throw MonitorError.protectedProcess(reason)
        }
        // Check again after inspection; never rely on the panel's cached policy.
        guard identity(for: expected.pid) == expected,
              executablePath(for: expected.pid) == executable else { throw MonitorError.changed }
        guard Darwin.kill(expected.pid, force ? SIGKILL : SIGTERM) == 0 else {
            throw MonitorError.signalFailed(String(cString: strerror(errno)))
        }
    }
}
