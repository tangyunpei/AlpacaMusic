import Foundation
import LocalAuthentication
import Security

protocol MusicCredentialStoring: Sendable {
    func load(for source: MusicSource) async throws -> [MusicSessionCookie]
    func save(_ cookies: [MusicSessionCookie], for source: MusicSource) async throws
    func delete(for source: MusicSource) async throws
}

/// This account type cannot name an arbitrary application or Keychain entry.
enum MusicCredentialAccount: String, Sendable, CaseIterable {
    case netease, qq, soda
    init(source: MusicSource) throws {
        switch source {
        case .netease: self = .netease
        case .qq: self = .qq
        case .soda: self = .soda
        default: throw MusicError.message(L10n.string("此来源不使用网页登录会话"))
        }
    }
    var title: String {
        switch self {
        case .netease: MusicSource.netease.title
        case .qq: MusicSource.qq.title
        case .soda: MusicSource.soda.title
        }
    }
}

/// Data-only injection point. Tests never call the system Keychain backend.
protocol MusicCredentialAccess: Sendable {
    func read(_ account: MusicCredentialAccount) async throws -> Data?
    func write(_ data: Data, for account: MusicCredentialAccount) async throws
    func remove(_ account: MusicCredentialAccount) async throws
}

actor MusicCredentialStore: MusicCredentialStoring {
    private let access: any MusicCredentialAccess
    private let maximumSize = 128 * 1024
    init() { access = KeychainMusicCredentialAccess() }
    init(access: any MusicCredentialAccess) { self.access = access }

    func load(for source: MusicSource) async throws -> [MusicSessionCookie] {
        let account = try MusicCredentialAccount(source: source)
        guard let data = try await access.read(account) else { return [] }
        guard data.count <= maximumSize,
              let cookies = try? JSONDecoder().decode([MusicSessionCookie].self, from: data) else {
            throw MusicError.message(L10n.string("保存的登录信息无法读取，请断开后重新登录"))
        }
        return DirectMusicAccess.sessionCookies(cookies, for: source)
    }
    /// Call only after the platform profile request confirms this session.
    func save(_ cookies: [MusicSessionCookie], for source: MusicSource) async throws {
        let account = try MusicCredentialAccount(source: source)
        let filtered = DirectMusicAccess.sessionCookies(cookies, for: source)
        guard !filtered.isEmpty else { throw MusicError.message(L10n.string("没有可保存的登录信息，请重新登录")) }
        let data = try JSONEncoder().encode(filtered)
        guard data.count <= maximumSize else { throw MusicError.message(L10n.string("登录信息过大，请重新登录")) }
        try Task.checkCancellation()
        try await access.write(data, for: account)
    }
    func delete(for source: MusicSource) async throws {
        try await access.remove(MusicCredentialAccount(source: source))
    }
}

/// SecItem APIs are current on macOS 26/27. The default macOS local Keychain also
/// supports ad-hoc builds, unlike access-group-based Data Protection Keychain.
/// The operating system's per-item application access control protects values.
/// There is no browser import, access group sharing, or synchronizable storage.
actor KeychainMusicCredentialAccess: MusicCredentialAccess {
    static let service = "dev.byalpaca.music.direct-session.v1"
    static func query(for account: MusicCredentialAccount) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account.rawValue,
         kSecAttrSynchronizable as String: false]
    }
    func read(_ account: MusicCredentialAccount) throws -> Data? {
        var query = Self.query(for: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        // Disallow LocalAuthentication UI. The file-based macOS Keychain may
        // still request ACL approval: this flag only suppresses Data Protection
        // authentication UI. Stable code signing preserves application identity
        // across updates; it does not override the user's Keychain permissions.
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw storageError(status) }
        return data
    }
    func write(_ data: Data, for account: MusicCredentialAccount) throws {
        let query = Self.query(for: account)
        let values = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = data
            newItem[kSecAttrLabel as String] = "AlpacaMusic · \(account.title)"
            let added = SecItemAdd(newItem as CFDictionary, nil)
            guard added == errSecSuccess else { throw storageError(added) }
        } else if status != errSecSuccess { throw storageError(status) }
    }
    func remove(_ account: MusicCredentialAccount) throws {
        let status = SecItemDelete(Self.query(for: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw storageError(status) }
    }
    private func storageError(_ status: OSStatus) -> MusicError {
        // Never include cookie values or URLs in diagnostics.
        .message(L10n.string("无法访问 AlpacaMusic 的登录信息（\(String(status))），请解锁钥匙串后重试"))
    }
}

actor MemoryMusicCredentialAccess: MusicCredentialAccess {
    private var values: [MusicCredentialAccount: Data] = [:]
    func read(_ account: MusicCredentialAccount) -> Data? { values[account] }
    func write(_ data: Data, for account: MusicCredentialAccount) { values[account] = data }
    func remove(_ account: MusicCredentialAccount) { values.removeValue(forKey: account) }
}

actor MemoryMusicCredentialStore: MusicCredentialStoring {
    private let store = MusicCredentialStore(access: MemoryMusicCredentialAccess())
    func load(for source: MusicSource) async throws -> [MusicSessionCookie] { try await store.load(for: source) }
    func save(_ cookies: [MusicSessionCookie], for source: MusicSource) async throws { try await store.save(cookies, for: source) }
    func delete(for source: MusicSource) async throws { try await store.delete(for: source) }
}
