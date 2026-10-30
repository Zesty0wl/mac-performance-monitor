import Foundation
import Security

/// Code-signing details for a binary on disk, gathered with the Security
/// framework (no `codesign` subprocess). Surfaces both the human-readable
/// signature picture *and* the exact fields needed to author a binary rule in an
/// `com.apple.configuration.app.settings` MDM declaration — CDHash, TeamID,
/// SigningID, PathPrefix and SigningState
/// (https://github.com/apple/device-management, app.settings.yaml).
struct CodeSignInfo: Sendable, Equatable {
    /// The binary's path — and the `PathPrefix` candidate for app.settings.
    var path: String
    var format: String?

    // --- app.settings binary-rule fields ---
    /// `kSecCodeInfoIdentifier` — the app.settings **SigningID**.
    var signingID: String?
    /// `kSecCodeInfoTeamIdentifier` — the app.settings **TeamID**
    /// (Apple platform binaries have none; the rule uses the literal `*APPLE*`).
    var teamID: String?
    /// The canonical code-directory hash, hex — the app.settings **CDHash**.
    var cdHash: String?
    /// Every code-directory hash (universal binaries carry one per architecture /
    /// digest), labelled with its digest, for picking the right CDHash.
    var cdHashes: [LabelledHash]
    /// Best-effort app.settings **SigningState**, derived from the anchor + leaf.
    var signingState: SigningState

    // --- general codesign picture ---
    /// Certificate common names, leaf first (the "Authority" chain `codesign` prints).
    var authorities: [String]
    var isAdHoc: Bool
    /// Whether the binary carries a signature at all.
    var isSigned: Bool
    /// On-disk signature validity (the "satisfies its Designated Requirement" check).
    var validity: Validity
    var signedTimestamp: Date?
    var flagsDescription: String?
    var designatedRequirement: String?

    struct LabelledHash: Sendable, Equatable, Identifiable {
        var id: String { label + hex }
        var label: String
        var hex: String
    }

    /// The app.settings `SigningState` enum, plus the two states that are not part
    /// of the MDM enum but matter when reading a signature (`adHoc`, `unsigned`).
    enum SigningState: String, Sendable {
        case all = "All"
        case testFlight = "TestFlight"
        case developerID = "DeveloperID"
        case enterprise = "Enterprise"
        case appStore = "AppStore"
        case apple = "Apple"
        case adHoc = "Ad-hoc"
        case unsigned = "Unsigned"

        /// Whether this is one of the six values app.settings accepts.
        var isAppSettingsValue: Bool {
            switch self {
            case .adHoc, .unsigned: return false
            default: return true
            }
        }
    }

    enum Validity: Sendable, Equatable {
        case valid
        case invalid(String)
        case unsigned
    }

    /// For an Apple platform binary with no team, the app.settings rule wants the
    /// literal `*APPLE*` in the TeamID field; otherwise the real team (or nil).
    var appSettingsTeamID: String? {
        if let teamID, !teamID.isEmpty { return teamID }
        return signingState == .apple ? "*APPLE*" : nil
    }

    /// The `PathPrefix` candidate: the enclosing `.app` bundle when the binary
    /// lives in one (the natural prefix for an MDM rule), else the binary path.
    var pathPrefixCandidate: String {
        if let r = path.range(of: ".app/") { return String(path[..<r.lowerBound]) + ".app" }
        return path
    }
}

extension CodeSignInfo {
    /// Inspect the binary at `path`. Synchronous and a touch slow (it reads the
    /// signature off disk), so call it off the main thread. Never throws — an
    /// unreadable or unsigned binary comes back with `isSigned == false`.
    static func inspect(path: String) -> CodeSignInfo {
        var result = CodeSignInfo(
            path: path, format: nil, signingID: nil, teamID: nil, cdHash: nil, cdHashes: [],
            signingState: .unsigned, authorities: [], isAdHoc: false, isSigned: false,
            validity: .unsigned, signedTimestamp: nil, flagsDescription: nil,
            designatedRequirement: nil)

        let url = URL(fileURLWithPath: path) as CFURL
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url, [], &staticCode) == errSecSuccess,
            let staticCode
        else { return result }

        // On-disk validity (also tells us "unsigned" cleanly).
        let checkFlags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures)
        let status = SecStaticCodeCheckValidity(staticCode, checkFlags, nil)
        switch status {
        case errSecSuccess: result.validity = .valid
        case errSecCSUnsigned: result.validity = .unsigned
        default: result.validity = .invalid(Self.message(for: status))
        }

        let infoFlags = SecCSFlags(
            rawValue: kSecCSSigningInformation | kSecCSInternalInformation
                | kSecCSRequirementInformation)
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, infoFlags, &info) == errSecSuccess,
            let dict = info as? [String: Any]
        else { return result }

        result.signingID = dict[kSecCodeInfoIdentifier as String] as? String
        result.teamID = dict[kSecCodeInfoTeamIdentifier as String] as? String
        result.format = dict[kSecCodeInfoFormat as String] as? String
        result.signedTimestamp =
            (dict[kSecCodeInfoTimestamp as String] as? Date)
            ?? (dict[kSecCodeInfoTime as String] as? Date)

        // CDHashes. `kSecCodeInfoUnique` is the canonical cdhash; the per-arch list
        // (internal info) lets the user pick the one for their architecture.
        if let unique = dict[kSecCodeInfoUnique as String] as? Data {
            result.cdHash = unique.hexEncoded
        }
        if let hashes = dict[kSecCodeInfoCdHashes as String] as? [Data] {
            result.cdHashes = hashes.enumerated().map { idx, data in
                LabelledHash(label: "cdhash \(idx + 1)", hex: data.hexEncoded)
            }
            if result.cdHash == nil { result.cdHash = result.cdHashes.first?.hex }
        }

        if let rawNumber = dict[kSecCodeInfoFlags as String] as? NSNumber {
            let raw = rawNumber.uint32Value
            result.isAdHoc = (raw & Self.adhocFlag) != 0
            result.flagsDescription = Self.describeFlags(raw)
        }

        if let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate] {
            result.authorities = certs.compactMap { Self.commonName(of: $0) }
        }
        result.isSigned =
            !(result.authorities.isEmpty && result.signingID == nil)
            && result.validity != .unsigned

        // Designated Requirement text.
        var requirement: SecRequirement?
        if SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
            let requirement
        {
            var reqString: CFString?
            if SecRequirementCopyString(requirement, [], &reqString) == errSecSuccess {
                result.designatedRequirement = reqString as String?
            }
        }

        result.signingState = Self.deriveSigningState(
            staticCode: staticCode, authorities: result.authorities,
            isAdHoc: result.isAdHoc, isSigned: result.isSigned)
        return result
    }

    /// Map the signature to the closest app.settings `SigningState`. A common
    /// name is just text, and a self-signed certificate can claim "Developer ID
    /// Application", so every state but `.all` first requires a chain to Apple's
    /// root. Developer ID and the Mac App Store are then read from the marker
    /// extensions Apple puts in those certificates; the rest from the leaf name
    /// of the Apple-issued certificate.
    private static func deriveSigningState(
        staticCode: SecStaticCode, authorities: [String], isAdHoc: Bool, isSigned: Bool
    ) -> SigningState {
        if !isSigned { return .unsigned }
        if isAdHoc { return .adHoc }
        if satisfies(staticCode, "anchor apple") { return .apple }
        guard satisfies(staticCode, "anchor apple generic") else { return .all }
        if satisfies(
            staticCode,
            "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists "
                + "and certificate leaf[field.1.2.840.113635.100.6.1.13] exists")
        {
            return .developerID
        }
        if satisfies(
            staticCode,
            "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists")
        {
            return .appStore
        }
        let leaf = authorities.first ?? ""
        if leaf.hasPrefix("Apple Mac OS Application Signing")
            || leaf.hasPrefix("3rd Party Mac Developer Application")
        {
            return .appStore
        }
        if leaf.hasPrefix("Apple Distribution") { return .enterprise }
        return .all
    }

    /// Whether the code satisfies a code-signing requirement string (used for the
    /// `anchor apple` platform-binary test).
    private static func satisfies(_ code: SecStaticCode, _ text: String) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
            let requirement
        else { return false }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    private static func commonName(of certificate: SecCertificate) -> String? {
        var name: CFString?
        guard SecCertificateCopyCommonName(certificate, &name) == errSecSuccess else { return nil }
        return name as String?
    }

    /// Code-signing flag bits from `<Security/CSCommon.h>` (`SecCodeSignatureFlags`),
    /// which the C enum does not surface to Swift. Stable ABI values.
    private static let adhocFlag: UInt32 = 0x0002
    private static let flagBits: [(UInt32, String)] = [
        (0x0001, "host"), (0x0002, "adhoc"), (0x0100, "hard"), (0x0200, "kill"),
        (0x0800, "restrict"), (0x1000, "enforcement"), (0x2000, "library-validation"),
        (0x10000, "runtime"),
    ]

    private static func describeFlags(_ raw: UInt32) -> String? {
        let present = flagBits.filter { raw & $0.0 != 0 }.map { $0.1 }
        let hex = String(format: "0x%x", raw)
        return present.isEmpty ? hex : "\(hex) (\(present.joined(separator: ", ")))"
    }

    private static func message(for status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
    }
}

extension Data {
    /// Lowercase hex, the form `codesign` and app.settings use for CDHash.
    fileprivate var hexEncoded: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
