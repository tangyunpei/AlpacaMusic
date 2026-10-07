import Foundation
import Testing
@testable import AlpacaMusic

private actor SourceFixture {
    private(set) var requests: [URLRequest] = []
    func respond(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = request.url!
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let id = query.first { $0.name == "id" }?.value ?? ""
        let body: String
        var status = 200
        switch url.path() {
        case "/timeout/cloudsearch": throw URLError(.timedOut)
        case "/broken/cloudsearch": status = 503; body = "{}"
        case "/html/cloudsearch": body = "<html>wrong server</html>"
        case "/cloudsearch": body = #"{"code":200,"result":{"songs":[{"id":42,"name":"Song","ar":[{"name":"Artist"}],"al":{"name":"Album","picUrl":"https://images.example/cover.jpg"},"dt":123000}]}}"#
        case "/song/url/v1":
            switch id {
            case "1": status = 404; body = "{}"
            case "2": body = #"{"code":200,"data":[{"id":2,"code":403,"url":null}]}"#
            case "3": body = #"{"code":200,"data":[{"id":3,"code":200,"url":"https://audio.example/trial.mp3","freeTrialInfo":{"start":0,"end":30}}]}"#
            case "4": body = #"{"code":200,"data":[{"id":999,"code":200,"url":"https://audio.example/wrong-song.mp3"}]}"#
            default: body = #"{"code":200,"data":[{"id":42,"code":200,"url":"https://audio.example/song.mp3"}]}"#
            }
        case "/song/url": body = #"{"code":200,"data":[{"id":1,"code":200,"url":"https://audio.example/legacy.mp3"}]}"#
        case "/search": body = #"{"result":100,"data":{"list":[{"songmid":"abc","songname":"QQ Song","singer":[{"name":"Singer"}],"albumname":"Record","albummid":"album","interval":60}]}}"#
        case "/song/urls":
            if id == "login" { body = #"{"result":301}"# }
            else if id == "missing" { body = #"{"result":100,"data":{}}"# }
            else { body = #"{"result":100,"data":{"abc":"https://audio.example/qq.m4a"}}"# }
        default: status = 404; body = "{}"
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!)
    }
}

@Suite("Configurable native source adapters") struct SourceTests {
    private func config(_ kind: MusicSource, suffix: String = "") -> SourceConfiguration { SourceConfiguration(kind: kind, endpoint: "http://127.0.0.1:3300\(suffix)", enabled: true) }
    private func song(_ source: MusicSource, id: String) -> Track { Track(id: "\(source.rawValue):\(id)", title: "Fixture", artist: "Test", album: "Test", duration: 1, source: source, sourceID: id) }

    @Test func configurationsRequireExplicitValidEndpoints() throws {
        #expect(try SourceService.validatedConfigurations([]) == SourceConfiguration.defaults)
        #expect(SourceConfiguration.defaults.allSatisfy { !$0.enabled && $0.endpoint.isEmpty })
        #expect(throws: SourceFailure.self) { try SourceService.validatedURL("file:///etc/passwd") }
        #expect(throws: SourceFailure.self) { try SourceService.validatedURL("https://user:password@example.com") }
        #expect(throws: SourceFailure.self) { try SourceService.validatedConfigurations([SourceConfiguration(kind: .qq, enabled: true)]) }
        #expect(throws: SourceFailure.self) { try SourceService.validatedConfigurations([SourceConfiguration(kind: .qq, endpoint: "https://example.com?cookie=value")]) }
        #expect(throws: SourceFailure.self) { try SourceService.validatedConfigurations([config(.qq), config(.qq)]) }
        #expect(try SourceService.validatedConfigurations([SourceConfiguration(kind: .qq, endpoint: "https://example.com/prefix/")]).last?.endpoint == "https://example.com/prefix")
    }
    @Test func normalizesNeteaseAndQQSongsWithoutCouplingPlayback() async throws {
        let fixture = SourceFixture(), service = SourceService(transport: { try await fixture.respond($0) })
        let results = await service.search("test", configurations: [config(.netease), config(.qq)])
        let netease = try #require(results.first { $0.source == .netease }?.tracks.first)
        #expect(netease.id == "netease:42" && netease.artist == "Artist" && netease.duration == 123)
        let qq = try #require(results.first { $0.source == .qq }?.tracks.first)
        #expect(qq.id == "qq:abc" && qq.artist == "Singer" && qq.duration == 60)
        #expect(try await service.resolve(qq, configurations: [config(.qq)]).absoluteString == "https://audio.example/qq.m4a")
        let requests = await fixture.requests
        #expect(requests.allSatisfy { !$0.httpShouldHandleCookies && $0.value(forHTTPHeaderField: "Cookie") == nil })
        #expect(requests.contains { $0.url?.query()?.contains("keywords=test") == true })
        #expect(requests.contains { $0.url?.query()?.contains("key=test") == true })
    }
    @Test func sourceFailuresAreIsolatedAndTimeoutsAreReadable() async throws {
        let fixture = SourceFixture(), service = SourceService(transport: { try await fixture.respond($0) })
        let results = await service.search("test", configurations: [config(.netease, suffix: "/broken"), config(.qq)])
        #expect(results.first { $0.source == .netease }?.error?.contains("503") == true)
        #expect(results.first { $0.source == .qq }?.tracks.count == 1)
        let timeout = await service.test(config(.netease, suffix: "/timeout"))
        #expect(!timeout.ok && timeout.message == L10n.string("音源请求超时，请检查服务是否可用"))
        let invalid = await service.test(config(.netease, suffix: "/html"))
        #expect(!invalid.ok && invalid.message == L10n.string("服务返回格式不兼容，请检查 API 类型与版本"))
    }
    @Test func unavailableAndTrialSongsNeverTriggerAccessFallbacks() async throws {
        let fixture = SourceFixture(), service = SourceService(transport: { try await fixture.respond($0) })
        #expect(try await service.resolve(song(.netease, id: "1"), configurations: [config(.netease)]).absoluteString == "https://audio.example/legacy.mp3")
        let before = await fixture.requests.count
        await #expect(throws: SourceFailure.self) { try await service.resolve(song(.netease, id: "2"), configurations: [config(.netease)]) }
        #expect(await fixture.requests.count == before + 1)
        await #expect(throws: SourceFailure.self) { try await service.resolve(song(.netease, id: "3"), configurations: [config(.netease)]) }
        await #expect(throws: SourceFailure.self) { try await service.resolve(song(.netease, id: "4"), configurations: [config(.netease)]) }
        await #expect(throws: SourceFailure.self) { try await service.resolve(song(.qq, id: "login"), configurations: [config(.qq)]) }
        await #expect(throws: SourceFailure.self) { try await service.resolve(song(.qq, id: "missing"), configurations: [config(.qq)]) }
    }
    @Test func disabledSourcesMakeNoRequestsAndDirectLinksAreValidated() async throws {
        let fixture = SourceFixture(), service = SourceService(transport: { try await fixture.respond($0) })
        #expect(await service.search("test", configurations: SourceConfiguration.defaults).isEmpty)
        #expect(await fixture.requests.isEmpty)
        await #expect(throws: SourceFailure.self) { try await service.resolve(song(.qq, id: "abc"), configurations: SourceConfiguration.defaults) }
        let track = Track(id: "url", title: "Stream", artist: "Test", album: "Test", duration: 0, source: .url, url: URL(string: "https://audio.example/radio"))
        #expect(try await service.resolve(track, configurations: []).scheme == "https")
        let tested = await service.test(config(.qq))
        #expect(tested.ok && tested.message == L10n.string("搜索接口连接成功；歌曲播放权限将在选歌时检查"))
    }
    @Test func oversizedResponsesAreRejected() async {
        let service = SourceService(transport: { request in (Data(repeating: 32, count: 4 * 1024 * 1024 + 1), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!) })
        let result = await service.test(config(.qq))
        #expect(!result.ok && result.message == L10n.string("音源响应过大"))
    }
}
