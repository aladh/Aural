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
    // MARK: - The dashboard grant, which no longer exists

    /// Deletes what the dashboard app left behind: the Web API access and refresh tokens, and
    /// the client id the user typed in to obtain them.
    ///
    /// Housekeeping on someone else's machine, run once per launch because there is nowhere
    /// cheaper to run it. The refresh token is a live credential for the retired dashboard flow,
    /// and leaving it in the user's keychain forever is not ours to do. Delete this
    /// once enough releases have passed that no installed copy still holds one.
    static func purgeDashboardGrant() {
        for key in ["spotify_access_token", "spotify_refresh_token", "spotify_expires_at"] {
            delete(key: key, service: "com.spotifly.oauth")
        }
        delete(key: "spotify_custom_client_id", service: "com.spotifly.config")
    }

    // MARK: - Keymaster grant

    private static let keymasterService = "dev.spotty.app.keymaster"
    private static let keymasterTokensKey = "keymaster_tokens"

    /// Stored as one item rather than a key per field, which is how the Web API tokens were
    /// kept. The four values are only meaningful together — an access token paired with another
    /// grant's expiry, or with a refresh token that has since rotated, is worse than nothing —
    /// and a single write cannot leave them half-updated.
    static func saveKeymasterTokens(_ tokens: KeymasterTokens) throws {
        try save(
            key: keymasterTokensKey,
            data: JSONEncoder().encode(tokens),
            service: keymasterService,
        )
        delete(key: keymasterTokensKey, service: PreviousInstallationIdentity.keychainService)
    }

    static func loadKeymasterTokens() -> KeymasterTokens? {
        if let data = load(key: keymasterTokensKey, service: keymasterService) {
            return KeymasterStoredGrantCodec.decode(data, source: .secure)
        }
        guard
            let data = load(
                key: keymasterTokensKey,
                service: PreviousInstallationIdentity.keychainService
            ),
            let tokens = KeymasterStoredGrantCodec.decode(data, source: .secure)
        else { return nil }

        do {
            try saveKeymasterTokens(tokens)
        } catch {
            SpottyLog.authentication.error("Stored grant identity migration failed reason=secure-save")
        }
        return tokens
    }

    static func clearKeymasterTokens() {
        delete(key: keymasterTokensKey, service: keymasterService)
        delete(key: keymasterTokensKey, service: PreviousInstallationIdentity.keychainService)
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
