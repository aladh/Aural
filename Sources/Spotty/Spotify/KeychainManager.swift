//
//  KeychainManager.swift
//  Spotty
//
//  Manages secure storage of Spotify OAuth tokens in the macOS/iOS Keychain
//

import Foundation
import LocalAuthentication
import Security

/// Manages secure storage of authentication tokens in the Keychain
nonisolated enum KeychainManager {
    // MARK: - Keymaster grant

    private static let keymasterService = "dev.spotty.app.keymaster"
    private static let keymasterTokensKey = "keymaster_tokens"
    private static let retiredKeymasterService = "dev.aural.app.keymaster"

    /// Stored as one item rather than a key per field, which is how the Web API tokens were
    /// kept. The four values are only meaningful together — an access token paired with another
    /// grant's expiry, or with a refresh token that has since rotated, is worse than nothing —
    /// and a single write cannot leave them half-updated.
    static func saveKeymasterTokens(_ tokens: KeymasterTokens) throws {
        clearRetiredKeymasterTokens()
        try save(
            key: keymasterTokensKey,
            data: JSONEncoder().encode(tokens),
            service: keymasterService,
        )
    }

    static func loadKeymasterTokens() -> KeymasterTokens? {
        clearRetiredKeymasterTokens()
        guard let data = load(key: keymasterTokensKey, service: keymasterService) else { return nil }
        return KeymasterStoredGrantCodec.decode(data)
    }

    static func clearKeymasterTokens() {
        clearRetiredKeymasterTokens()
        delete(key: keymasterTokensKey, service: keymasterService)
    }

    private static func clearRetiredKeymasterTokens() {
        delete(key: keymasterTokensKey, service: retiredKeymasterService)
    }

    // MARK: - Private Keychain Operations

    private static func save(key: String, data: Data, service: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        var addQuery = makeQuery(key: key, service: service)
        addQuery.merge(attributes) { _, new in new }

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }
        guard addStatus == errSecDuplicateItem else {
            throw KeychainError.saveFailed(addStatus)
        }

        // Update in place so Keychain keeps existing trusted app ACL entries.
        var updateQuery = makeQuery(key: key, service: service)
        updateQuery[kSecUseAuthenticationContext as String] = noninteractiveContext()
        let updateStatus = SecItemUpdate(
            updateQuery as CFDictionary,
            attributes as CFDictionary,
        )
        guard updateStatus == errSecSuccess else {
            throw KeychainError.saveFailed(updateStatus)
        }
    }

    private static func load(key: String, service: String) -> Data? {
        var query = makeQuery(key: key, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            return nil
        }

        return result as? Data
    }

    private static func delete(key: String, service: String) {
        var query = makeQuery(key: key, service: service)
        query[kSecUseAuthenticationContext as String] = noninteractiveContext()
        SecItemDelete(query as CFDictionary)
    }

    private static func noninteractiveContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    /// File-based generic-password items, authorized by this process's code signature.
    ///
    /// `kSecUseDataProtectionKeychain` is omitted. That flag selects the data-protection
    /// keychain, whose entitlement-based access requires a provisioning profile. Spotty
    /// retains the file-based item so existing credentials remain discoverable.
    ///
    /// Self-signed development signatures are build-only: macOS records their changing
    /// CDHash in the item's partition ACL, so they cannot provide silent access across
    /// rebuilds. `build_and_run.sh` therefore requires an Apple-issued team signature;
    /// its stable Team ID is the reusable development access boundary.
    private static func makeQuery(key: String, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}

/// Errors that can occur during keychain operations
enum KeychainError: Error, LocalizedError {
    case saveFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .saveFailed(status):
            "Failed to save to keychain: \(status)"
        }
    }
}
