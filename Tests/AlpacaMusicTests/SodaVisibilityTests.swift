import Foundation
import Testing
@testable import AlpacaMusic

private actor HiddenSourceCredentialStore: MusicCredentialStoring {
    private(set) var reads: [MusicSource] = []
    private(set) var writes = 0
    private(set) var deletes = 0
    private let saved = [MusicSessionCookie(name: "sessionid", value: "fixture-hidden-session", domain: ".qishui.com")]

    func load(for source: MusicSource) -> [MusicSessionCookie] {
        reads.append(source)
        return source == .soda ? saved : []
    }
    func save(_ cookies: [MusicSessionCookie], for source: MusicSource) { writes += 1 }
    func delete(for source: MusicSource) { deletes += 1 }
}

@Suite struct SodaVisibilityTests {
    @MainActor @Test func startupSkipsHiddenAccountWithoutDeletingItsSavedSession() async throws {
        let store = HiddenSourceCredentialStore()
        let client = NativeMusicClient(providers: [], credentials: store)
        let accounts = ConnectedMusicAccounts(client: client)
        await accounts.restore()
        #expect(await store.reads == [.netease, .qq])
        #expect(try await client.restore(.soda) == nil)
        #expect(await store.reads == [.netease, .qq])
        #expect(await store.writes == 0)
        #expect(await store.deletes == 0)
        #expect(await client.connectedSources().isEmpty)
        #expect(await store.load(for: .soda).first?.value == "fixture-hidden-session")
    }
}
