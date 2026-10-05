import Foundation
import Security
import Synchronization
import Testing
@testable import AlpacaMusic

private let spotifyFixtureClientID = "0123456789abcdef0123456789abcdef"

private actor SpotifyCallbackFixture: SpotifyCallbackReceiving {
    let waits: Bool
    private(set) var expectedState: String?
    private(set) var cancelled = false
    private var receiving = false
    private var codeContinuation: CheckedContinuation<String, Error>?
    private var receivingContinuation: CheckedContinuation<Void, Never>?
    init(waits: Bool = false) { self.waits = waits }
    func start(expectedState: String) throws {
        if cancelled { throw CancellationError() }
        self.expectedState = expectedState
    }
    func code() async throws -> String {
        if cancelled { throw CancellationError() }
        receiving = true; receivingContinuation?.resume(); receivingContinuation = nil
        if !waits { return "fixture-auth-code" }
        return try await withCheckedThrowingContinuation { codeContinuation = $0 }
    }
    func waitUntilReceiving() async {
        if receiving { return }
        await withCheckedContinuation { receivingContinuation = $0 }
    }
    func cancel() {
        cancelled = true
        codeContinuation?.resume(throwing: CancellationError()); codeContinuation = nil
    }
}

private actor SpotifyTokenRequestFixture {
    private(set) var requests: [URLRequest] = []
    let responseData: Data
    let status: Int
    let responseURL: String
    init(json: String = "{\"access_token\":\"fixture-access\",\"token_type\":\"Bearer\",\"expires_in\":3600,\"refresh_token\":\"fixture-refresh\",\"scope\":\"user-library-read playlist-read-private\"}", status: Int = 200, responseURL: String = "https://accounts.spotify.com/api/token") {
        responseData = Data(json.utf8); self.status = status; self.responseURL = responseURL
    }
    func send(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (responseData, HTTPURLResponse(url: URL(string: responseURL)!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

@Suite struct SpotifyAuthorizationTests {
    @Test func pkceMatchesRFC7636VectorAndRandomSecretsAreURLSafe() throws {
        #expect(SpotifyAuthorization.codeChallenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let first = try SpotifyAuthorization.randomURLSafeString(byteCount: 64)
        let second = try SpotifyAuthorization.randomURLSafeString(byteCount: 64)
        #expect(first != second)
        #expect((43...128).contains(first.count))
        #expect(first.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
    }

    @Test func authorizationUsesPKCEAndIPLiteralWithoutSecretsOrImplicitGrant() throws {
        let url = try SpotifyAuthorization.authorizationURL(clientID: spotifyFixtureClientID, state: "unique-state", verifier: "private-verifier")
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(url.scheme == "https" && url.host == "accounts.spotify.com")
        #expect(query["response_type"] == "code")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["redirect_uri"] == "http://127.0.0.1:43821/callback")
        #expect(query["state"] == "unique-state")
        #expect(!url.absoluteString.contains("private-verifier"))
        #expect(query["client_secret"] == nil)
        #expect(!query["scope"]!.contains("user-read-email"))
        #expect(throws: SpotifyAuthorizationError.invalidClientID) {
            try SpotifyAuthorization.authorizationURL(clientID: "not-an-app-id", state: "x", verifier: "v")
        }
    }

    @Test func callbackAcceptsOnlyExactHostPathMethodAndMatchingSingleState() throws {
        func request(_ target: String, method: String = "GET", host: String = SpotifyLoopbackReceiver.host, extra: String = "") -> Data {
            Data("\(method) \(target) HTTP/1.1\r\nHost: \(host)\r\n\(extra)\r\n".utf8)
        }
        let parsed = SpotifyLoopbackReceiver.parseRequest(request("/callback?code=one%2Btwo&state=expected"), expectedState: "expected")
        #expect(try parsed?.get() == "one+two")
        for data in [
            request("/callback?code=x&state=wrong"),
            request("/callback?code=x&state=expected&state=expected"),
            request("/callback?code=x&code=y&state=expected"),
            request("/callback?code=x&error=access_denied&state=expected"),
            request("/callback?state=expected"),
            request("/callback?code=&state=expected"),
            request("/callback?code=x&state=expected", method: "POST"),
            request("/callback?code=x&state=expected", host: "localhost:43821"),
            request("/callback?code=x&state=expected", host: "evil.example"),
            request("/callback/elsewhere?code=x&state=expected"),
            request("http://127.0.0.1:43821/callback?code=x&state=expected"),
            request("/callback?code=x&state=expected#fragment"),
            request("/callback?code=x&state=expected", extra: "Host: evil.example\r\n"),
            request("/callback?code=x&state=expected", extra: "Transfer-Encoding: chunked\r\n"),
            request("/callback?code=x&state=expected", extra: "Content-Length: 123\r\n"),
            Data(repeating: 65, count: SpotifyLoopbackReceiver.maximumRequestBytes + 1)
        ] {
            #expect(SpotifyLoopbackReceiver.parseRequest(data, expectedState: "expected") == nil)
        }
    }

    @Test func callbackDenialStillRequiresMatchingStateAndNeverReturnsRawError() {
        let data = Data("GET /callback?error=secret-server-diagnostic&state=expected HTTP/1.1\r\nHost: 127.0.0.1:43821\r\n\r\n".utf8)
        #expect(SpotifyLoopbackReceiver.parseRequest(data, expectedState: "wrong") == nil)
        #expect(throws: SpotifyAuthorizationError.denied) { try SpotifyLoopbackReceiver.parseRequest(data, expectedState: "expected")?.get() }
        #expect(!SpotifyAuthorizationError.denied.localizedDescription.contains("secret-server-diagnostic"))
    }

    @Test func browserCodeExchangeUsesSameVerifierAndStateWithoutPersistingAnything() async throws {
        let callback = SpotifyCallbackFixture(), transport = SpotifyTokenRequestFixture()
        let urls = Mutex<[URL]>([])
        let auth = SpotifyAuthorization(transport: { await transport.send($0) }, openBrowser: { url in urls.withLock { $0.append(url) }; return true }, callbackFactory: { callback })
        let token = try await auth.authorize(clientID: spotifyFixtureClientID)
        let url = try #require(urls.withLock { $0.first })
        let browserQuery = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        let request = try #require(await transport.requests.first)
        let body = try #require(String(data: request.httpBody!, encoding: .utf8))
        let fields = Dictionary(uniqueKeysWithValues: URLComponents(string: "http://fixture/?\(body)")!.queryItems!.map { ($0.name, $0.value ?? "") })
        #expect(await callback.expectedState == browserQuery["state"])
        #expect(await callback.cancelled)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(fields["code"] == "fixture-auth-code")
        #expect(fields["redirect_uri"] == browserQuery["redirect_uri"])
        #expect(SpotifyAuthorization.codeChallenge(for: fields["code_verifier"]!) == browserQuery["code_challenge"])
        #expect(fields["client_secret"] == nil)
        #expect(token.accessToken == "fixture-access" && token.refreshToken == "fixture-refresh")
        #expect(token.scopes == ["user-library-read", "playlist-read-private"])
        #expect(!token.isExpired())
    }

    @Test func cancellationReleasesPendingCallbackAndAllowsAnotherAttempt() async throws {
        let callback = SpotifyCallbackFixture(waits: true), transport = SpotifyTokenRequestFixture()
        let auth = SpotifyAuthorization(transport: { await transport.send($0) }, openBrowser: { _ in true }, callbackFactory: { callback })
        let task = Task { try await auth.authorize(clientID: spotifyFixtureClientID) }
        await callback.waitUntilReceiving()
        await #expect(throws: SpotifyAuthorizationError.alreadyAuthorizing) { try await auth.authorize(clientID: spotifyFixtureClientID) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await callback.cancelled)
        #expect(await transport.requests.isEmpty)
        // Fixture was deliberately cancelled: a new attempt must reach it,
        // rather than being rejected by a stale "authorizing" flag.
        await #expect(throws: CancellationError.self) { try await auth.authorize(clientID: spotifyFixtureClientID) }
    }

    @Test func browserOpenFailureStopsCallbackWithoutTokenRequest() async {
        let callback = SpotifyCallbackFixture(), transport = SpotifyTokenRequestFixture()
        let auth = SpotifyAuthorization(transport: { await transport.send($0) }, openBrowser: { _ in false }, callbackFactory: { callback })
        await #expect(throws: SpotifyAuthorizationError.browserUnavailable) { try await auth.authorize(clientID: spotifyFixtureClientID) }
        #expect(await callback.cancelled)
        #expect(await transport.requests.isEmpty)
    }

    @Test func refreshRetainsOriginalRefreshTokenAndEncodesFormCharacters() async throws {
        let transport = SpotifyTokenRequestFixture(json: "{\"access_token\":\"new-access\",\"token_type\":\"Bearer\",\"expires_in\":3600}")
        let auth = SpotifyAuthorization(transport: { await transport.send($0) })
        let refreshed = try await auth.refresh(clientID: spotifyFixtureClientID, refreshToken: "old+refresh&value=1")
        #expect(refreshed.refreshToken == "old+refresh&value=1")
        let body = try #require(String(data: await transport.requests[0].httpBody!, encoding: .utf8))
        #expect(body.contains("refresh_token=old%2Brefresh%26value%3D1"))
        #expect(body.contains("grant_type=refresh_token"))
        #expect(!body.contains("client_secret"))
    }

    @Test func revokedRefreshAndRedirectedTokenResponsesNeverBecomeSessions() async {
        let revoked = SpotifyTokenRequestFixture(json: "{\"error\":\"invalid_grant\",\"error_description\":\"private-data\"}", status: 400)
        let auth = SpotifyAuthorization(transport: { await revoked.send($0) })
        await #expect(throws: SpotifyAuthorizationError.expiredSession) { try await auth.refresh(clientID: spotifyFixtureClientID, refreshToken: "fixture") }
        let redirected = SpotifyTokenRequestFixture(responseURL: "https://other.example/token")
        let second = SpotifyAuthorization(transport: { await redirected.send($0) })
        await #expect(throws: SpotifyAuthorizationError.invalidToken) { try await second.refresh(clientID: spotifyFixtureClientID, refreshToken: "fixture") }
    }

    @Test func invalidTokenPayloadsAreRejected() async {
        for json in ["{}", "{\"access_token\":\"x\",\"token_type\":\"Basic\",\"expires_in\":3600}", "{\"access_token\":\"\",\"token_type\":\"Bearer\",\"expires_in\":3600}", "{\"access_token\":\"x\",\"token_type\":\"Bearer\",\"expires_in\":0}"] {
            let fixture = SpotifyTokenRequestFixture(json: json)
            let auth = SpotifyAuthorization(transport: { await fixture.send($0) })
            await #expect(throws: SpotifyAuthorizationError.invalidToken) { try await auth.refresh(clientID: spotifyFixtureClientID, refreshToken: "fixture") }
        }
    }

    @Test func credentialsAreBoundToClientAndStoredSeparatelyFromDirectSessions() async throws {
        let access = MemorySpotifyCredentialAccess(), store = SpotifyCredentialStore(access: access)
        let token = SpotifyToken(accessToken: "fixture", refreshToken: "refresh", expiresAt: Date().addingTimeInterval(3600), scopes: [])
        let secondID = "abcdef0123456789abcdef0123456789"
        try await store.save(token, clientID: spotifyFixtureClientID)
        #expect(try await store.load(clientID: spotifyFixtureClientID) == token)
        #expect(try await store.load(clientID: secondID) == nil)
        let bytes = try #require(await access.read(clientID: spotifyFixtureClientID))
        await access.write(bytes, clientID: secondID)
        await #expect(throws: SpotifyAuthorizationError.invalidStoredCredential) { try await store.load(clientID: secondID) }
        let query = KeychainSpotifyCredentialAccess.query(clientID: spotifyFixtureClientID)
        #expect(query[kSecAttrService as String] as? String == "dev.byalpaca.music.spotify-oauth.v1")
        #expect(query[kSecAttrAccount as String] as? String == spotifyFixtureClientID)
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(query[kSecAttrAccessGroup as String] == nil)
        try await store.delete(clientID: spotifyFixtureClientID)
        try await store.delete(clientID: spotifyFixtureClientID)
        #expect(try await store.load(clientID: spotifyFixtureClientID) == nil)
    }
}

@Suite(.serialized) struct SpotifyLoopbackTests {
    @Test func loopbackRejectsWrongStateThenReceivesValidCallback() async throws {
        let receiver = SpotifyLoopbackReceiver()
        defer { Task { await receiver.cancel() } }
        try await receiver.start(expectedState: "fixture-loopback-state")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let wrong = URL(string: SpotifyAuthorization.redirectURI + "?code=fixture&state=wrong")!
        let (_, rejected) = try await session.data(from: wrong)
        #expect((rejected as? HTTPURLResponse)?.statusCode == 400)
        let correct = URL(string: SpotifyAuthorization.redirectURI + "?code=fixture&state=fixture-loopback-state")!
        let (page, response) = try await session.data(from: correct)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(!String(decoding: page, as: UTF8.self).contains("fixture-loopback-state"))
        #expect(try await receiver.code() == "fixture")
        await receiver.cancel()
    }

    @Test func occupiedPortFailsClearlyAndCancelClosesListener() async throws {
        let first = SpotifyLoopbackReceiver(), second = SpotifyLoopbackReceiver()
        defer { Task { await first.cancel(); await second.cancel() } }
        try await first.start(expectedState: "first")
        await #expect(throws: SpotifyAuthorizationError.callbackUnavailable) { try await second.start(expectedState: "second") }
        await first.cancel()
        await #expect(throws: CancellationError.self) { try await first.code() }
    }
}
