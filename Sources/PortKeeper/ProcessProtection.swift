import Foundation
import Security
import Darwin

enum ProcessProtection {
    /// A port number or a displayed command name is never evidence that a
    /// process is safe to stop. Use its live identity, executable and signature.
    static func reason(identity: ProcessIdentity?, executable: String?, appleSigned: Bool?) -> String? {
        guard let identity else { return "Process identity could not be verified." }
        guard identity.pid > 1 else { return "Essential system process." }
        guard identity.pid != getpid() else { return "PortKeeper cannot stop itself." }
        guard identity.uid == getuid() else { return "Owned by another account or the system." }
        guard let executable, executable.hasPrefix("/"), !executable.isEmpty else {
            return "Executable could not be verified."
        }
        let path = URL(fileURLWithPath: executable).resolvingSymlinksInPath().standardizedFileURL.path
        let protectedFolders = [
            "/System", "/bin", "/sbin", "/usr/bin", "/usr/sbin", "/usr/lib", "/usr/libexec",
            "/Library/Apple", "/Library/CoreServices"
        ]
        if protectedFolders.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return "macOS system executable."
        }
        guard let appleSigned else { return "Executable signing status could not be verified." }
        if appleSigned { return "Apple-signed app or service." }
        return nil
    }

    static func liveReason(identity: ProcessIdentity?, executable: String?) -> String? {
        // Avoid expensive signature work for processes already protected by
        // identity or system location. The final signal path always rechecks.
        if let reason = reason(identity: identity, executable: executable, appleSigned: false) {
            return reason
        }
        return reason(identity: identity, executable: executable,
                      appleSigned: identity.flatMap { isAppleSigned(pid: $0.pid) })
    }

    private static func isAppleSigned(pid: Int32) -> Bool? {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else { return nil }
        var requirement: SecRequirement?
        // "anchor apple" identifies Apple itself. "anchor apple generic"
        // would also include third-party Developer ID signatures.
        guard SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return nil }
        switch SecCodeCheckValidity(code, [], requirement) {
        case errSecSuccess: return true
        case errSecCSReqFailed, errSecCSUnsigned: return false
        default: return nil
        }
    }
}
