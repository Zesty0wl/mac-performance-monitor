import Darwin
import Foundation

/// Looks up the host name registered for an IP address (a PTR record).
public enum ReverseDNS {
    /// The name for `address` (IPv4 or IPv6, as text), or nil when it is not
    /// an IP address or has no name.
    ///
    /// This asks the Mac's DNS resolver, so the address leaves the Mac. Call
    /// it only when the user asked for names, and off the main thread: an
    /// unanswered lookup can take seconds.
    public static func hostName(for address: String) -> String? {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        hints.ai_socktype = SOCK_STREAM
        var parsed: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(address, nil, &hints, &parsed) == 0, let parsed else { return nil }
        defer { freeaddrinfo(parsed) }

        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
            parsed.pointee.ai_addr, parsed.pointee.ai_addrlen, &host, socklen_t(host.count), nil,
            0, NI_NAMEREQD)
        guard result == 0 else { return nil }
        let name = String(cString: host).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return name.isEmpty || name == address ? nil : name
    }

    /// Whether looking `address` up would tell the resolver anything: false
    /// for loopback, link-local and unspecified addresses, which never have a
    /// public name and are not worth a query.
    public static func isWorthLookingUp(_ address: String) -> Bool {
        let lower = address.lowercased()
        if lower.isEmpty || lower == "::" || lower == "::1" || lower == "0.0.0.0" { return false }
        if lower.hasPrefix("127.") || lower.hasPrefix("169.254.") || lower.hasPrefix("fe80:") {
            return false
        }
        return true
    }
}
