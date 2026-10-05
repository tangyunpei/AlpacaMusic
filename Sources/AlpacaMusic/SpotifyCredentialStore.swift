import Foundation
import LocalAuthentication
import Security

protocol SpotifyCredentialStoring: Sendable {
    func load(clientID: String) async throws -> SpotifyToken?
    func save(_ token: SpotifyToken, clientID: String) async throws
    func delete(clientID: String) async throws
}

protocol SpotifyCredentialAccess: Sendable {
    func read(clientID: String) async throws -> Data?
    func write(_ data: Data, clientID: String) async throws
    func remove(clientID: String) async throws
}

actor SpotifyCredentialStore: SpotifyCredentialStoring {
    private struct StoredCredential: Codable { let clientID: String; let token: SpotifyToken }
    private let access: any SpotifyCredentialAccess
    init(access: any SpotifyCredentialAccess = KeychainSpotifyCredentialAccess()) { self.access = access }

    func load(clientID: String) async throws -> SpotifyToken? {
        let clientID = try SpotifyAuthorization.validatedClientID(clientID)
        guard let data = try await access.read(clientID: clientID) else { return nil }
        guard data.count <= 128 * 1024, let stored = try? JSONDecoder().decode(StoredCredential.self, from: data),
              stored.clientID == clientID, Self.valid(stored.token) else { throw SpotifyAuthorizationError.invalidStoredCredential }
        return stored.token
    }
    /// Only called after an authenticated profile request confirms the account.
    func save(_ token: SpotifyToken, clientID: String) async throws {
        let clientID = try SpotifyAuthorization.validatedClientID(clientID)
        guard Self.valid(token) else { throw SpotifyAuthorizationError.invalidStoredCredential }
        let data = try JSONEncoder().encode(StoredCredential(clientID: clientID, token: token))
        guard data.count <= 128 * 1024 else { throw SpotifyAuthorizationError.invalidStoredCredential }
        try Task.checkCancellation()
        try await access.write(data, clientID: clientID)
    }
    func delete(clientID: String) async throws {
        try await access.remove(clientID: SpotifyAuthorization.validatedClientID(clientID))
    }
    private static func valid(_ token: SpotifyToken) -> Bool {
        !token.accessToken.isEmpty && token.accessToken.utf8.count <= 16384 &&
        !token.refreshToken.isEmpty && token.refreshToken.utf8.count <= 16384 &&
        token.expiresAt.timeIntervalSince1970.isFinite && token.scopes.count <= 100
    }
}

/// Separate from direct music Cookies, scoped to this app and the registered
/// Spotify client. No shared browser, synchronization, or foreign-app access.
actor KeychainSpotifyCredentialAccess: SpotifyCredentialAccess {
    static let service = "dev.byalpaca.music.spotify-oauth.v1"
    static func query(clientID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: clientID,
         kSecAttrSynchronizable as String: false]
    }
    func read(clientID: String) throws -> Data? {
        var query = Self.query(clientID: clientID)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        let context = LAContext(); context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw SpotifyAuthorizationError.credentialStorage(Int(status)) }
        return data
    }
    func write(_ data: Data, clientID: String) throws {
        let query = Self.query(clientID: clientID)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "AlpacaMusic · Spotify"
            let result = SecItemAdd(item as CFDictionary, nil)
            guard result == errSecSuccess else { throw SpotifyAuthorizationError.credentialStorage(Int(result)) }
        } else if status != errSecSuccess { throw SpotifyAuthorizationError.credentialStorage(Int(status)) }
    }
    func remove(clientID: String) throws {
        let status = SecItemDelete(Self.query(clientID: clientID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SpotifyAuthorizationError.credentialStorage(Int(status)) }
    }
}

actor MemorySpotifyCredentialAccess: SpotifyCredentialAccess {
    private var values: [String: Data] = [:]
    func read(clientID: String) -> Data? { values[clientID] }
    func write(_ data: Data, clientID: String) { values[clientID] = data }
    func remove(clientID: String) { values.removeValue(forKey: clientID) }
}

actor MemorySpotifyCredentialStore: SpotifyCredentialStoring {
    private let store = SpotifyCredentialStore(access: MemorySpotifyCredentialAccess())
    func load(clientID: String) async throws -> SpotifyToken? { try await store.load(clientID: clientID) }
    func save(_ token: SpotifyToken, clientID: String) async throws { try await store.save(token, clientID: clientID) }
    func delete(clientID: String) async throws { try await store.delete(clientID: clientID) }
}
