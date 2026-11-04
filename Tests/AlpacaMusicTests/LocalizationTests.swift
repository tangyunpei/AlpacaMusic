import Foundation
import Observation
import Synchronization
import Testing
@testable import AlpacaMusic

@Suite struct LocalizationTests {
    @Test func systemLanguageNegotiatesSupportedLanguages() {
        #expect(AppLanguage.system.resolved(preferredLanguages: ["en-GB"]) == .english)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["zh-Hans-CN"]) == .simplifiedChinese)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["fr-FR", "zh-Hans"]) == .simplifiedChinese)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["es-ES"]) == .english)
        #expect(AppLanguage.english.resolved(preferredLanguages: ["zh-Hans"]) == .english)
        #expect(AppLanguage.simplifiedChinese.resolved(preferredLanguages: ["en"]) == .simplifiedChinese)
    }
    @Test func languagePreferenceSurvivesReloadAndRejectsUnknownIdentifiers() throws {
        let name = "AlpacaMusicTests.language." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(L10n.preference(in: defaults) == .system)
        defaults.set(AppLanguage.english.rawValue, forKey: L10n.preferenceKey)
        #expect(L10n.preference(in: try #require(UserDefaults(suiteName: name))) == .english)
        defaults.set("unsupported", forKey: L10n.preferenceKey)
        #expect(L10n.preference(in: defaults) == .system)
    }
    @Test func explicitBundlesLocalizeWithoutChangingGlobalState() {
        #expect(L10n.string("播放队列", language: .english) == "Play Queue")
        #expect(L10n.string("播放队列", language: .simplifiedChinese) == "播放队列")
        #expect(L10n.string("跟随系统", language: .english) == "Follow System")
        #expect(L10n.string("轨道光场", language: .english) == "Orbital Light")
    }
    @Test func typedInterpolationKeepsUserContentAndSupportsPluralCounts() {
        let name = "我的歌单 🎵"
        #expect(L10n.string("搜索「\(name)」", language: .english) == "Search “我的歌单 🎵”")
        #expect(L10n.string("已导入 \(1) 首音乐", language: .english) == "Imported 1 track")
        #expect(L10n.string("已导入 \(3) 首音乐", language: .english) == "Imported 3 tracks")
        #expect(L10n.string("已导入 \(0) 首音乐", language: .english) == "Imported 0 tracks")
        #expect(L10n.string("\(1) 个已启用音源", language: .english) == "1 source enabled")
        #expect(L10n.string("\(2) 个已启用音源", language: .english) == "2 sources enabled")
        #expect(L10n.string("已导入 \(3) 首音乐", language: .simplifiedChinese) == "已导入 3 首音乐")
        #expect(L10n.string("已导入「\(name)」：\(1) 首歌曲", language: .english) == "Imported “我的歌单 🎵”: 1 track")
        #expect(L10n.string("已导入 \(1) 首。\("Server message")", language: .english) == "Imported 1 track. Server message")
    }
    @Test func aLanguageChangeInvalidatesObservedText() {
        let state = LocalizationState(.english)
        let changed = Mutex(false)
        withObservationTracking {
            #expect(state.language == .english)
        } onChange: {
            changed.withLock { $0 = true }
        }
        state.language = .simplifiedChinese
        #expect(changed.withLock { $0 })
        #expect(state.language == .simplifiedChinese)
    }
    @Test func providerMessagesResolveInsideConcurrentTasks() async {
        await withTaskGroup(of: Bool.self) { group in
            for index in 0..<32 {
                group.addTask {
                    let language: AppLanguage = index.isMultiple(of: 2) ? .english : .simplifiedChinese
                    return L10n.string("网易云音乐", language: language) == (language == .english ? "NetEase Cloud Music" : "网易云音乐")
                }
            }
            for await result in group { #expect(result) }
        }
    }
}
