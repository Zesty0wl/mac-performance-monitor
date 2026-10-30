import Foundation
import Security

/// The Apple Developer **Team Identifier** of the currently running code — the
/// value codesign records as `subject.OU` in the signing leaf certificate (for
/// example "ABCDE12345") — or nil when the code has no team, i.e. an ad-hoc or
/// unsigned build.
///
/// This is the keystone of the portable XPC pin: the app and the privileged
/// helper each require their peer to belong to *their own* team, read here at
/// runtime, rather than a team baked into the source. A clone signed with any
/// Apple Developer account (paid or free) therefore connects without editing a
/// constant, while a team mismatch — the classic symptom of signing the two
/// halves with different certificates — is still rejected.
public func ownTeamIdentifier() -> String? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }

    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode
    else { return nil }

    var info: CFDictionary?
    let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
    guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
        let dict = info as? [String: Any]
    else { return nil }

    return dict[kSecCodeInfoTeamIdentifier as String] as? String
}

/// The code directory hash (cdhash) of the code at `url`, a bundle or a single
/// executable, or nil when it is unsigned or cannot be read.
public func codeDirectoryHash(ofCodeAt url: URL) -> Data? {
    var staticCode: SecStaticCode?
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
        let staticCode
    else { return nil }

    var info: CFDictionary?
    let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
    guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
        let dict = info as? [String: Any]
    else { return nil }

    return dict[kSecCodeInfoUnique as String] as? Data
}
