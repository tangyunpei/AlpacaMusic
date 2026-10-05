import Foundation
import JavaScriptCore
import Testing
@testable import AlpacaMusic

/// Synthetic browser adapter tests run the same mounting/status scripts without
/// network access, user accounts, real QR codes or solving any verification.
@Suite @MainActor struct NeteaseQRLoginTests {
    private func context() throws -> JSContext {
        let js = try #require(JSContext())
        js.evaluateScript(Self.browser)
        js.evaluateScript("function mount(attempt) {\n" + NeteaseQRAuthentication.mountScript + "\n}\nfunction status(attempt) {\n" + NeteaseQRAuthentication.statusScript + "\n}")
        #expect(js.exception == nil)
        return js
    }
    private func result(_ js: JSContext, _ call: String) throws -> [String: Any] {
        let json = try #require(js.evaluateScript("JSON.stringify(" + call + ")")?.toString())
        #expect(js.exception == nil)
        return try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }
    private func cookie(_ name: String = "MUSIC_U", value: String = "synthetic-session", domain: String = ".music.163.com", path: String = "/", expires: Date? = nil) throws -> MusicSessionCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name:name,.value:value,.domain:domain,.path:path,.secure:"TRUE"]
        if let expires { properties[.expires] = expires }
        return MusicSessionCookie(try #require(HTTPCookie(properties: properties)))
    }

    @Test func originChecksRejectAliasesCredentialsAndOtherPages() {
        for url in ["https://music.163.com/", "https://music.163.com", "https://music.163.com:443/#/"] {
            #expect(NeteaseQRAuthentication.isRoot(URL(string:url)))
        }
        for url in ["http://music.163.com/", "https://music.163.com.evil.invalid/", "https://evil.invalid/", "https://user@music.163.com/", "https://music.163.com:444/", "https://music.163.com/login", "https://music.163.com/?code=private", "https://music.163.com/%2f", "about:blank"] {
            #expect(!NeteaseQRAuthentication.isRoot(URL(string:url)))
        }
        #expect(!NeteaseQRAuthentication.isRoot(nil))
    }

    @Test func captchaSubframeIsPermittedButCannotBecomeMainDocument() {
        #expect(NeteaseQRAuthentication.allows(URL(string:"https://c.dun.163.com/api/v3/"), main:false))
        #expect(!NeteaseQRAuthentication.allows(URL(string:"https://c.dun.163.com/api/v3/"), main:true))
        #expect(!NeteaseQRAuthentication.allows(URL(string:"https://c.dun.163.com.evil.invalid/"), main:false))
        #expect(NeteaseQRAuthentication.allows(URL(string:"about:blank"), main:false))
        #expect(!NeteaseQRAuthentication.allows(URL(string:"about:blank"), main:true))
        #expect(!NeteaseQRAuthentication.allows(URL(string:"file:///tmp/login"), main:false))
        #expect(NeteaseQRAuthentication.allows(URL(string:"https://reg.163.com/"), main:true, popup:true))
        #expect(!NeteaseQRAuthentication.allows(URL(string:"https://evil.invalid/"), main:true, popup:true))
    }

    @Test func componentMountsOnlyAfterOfficialBootstrapIsReady() throws {
        let js = try context()
        js.evaluateScript("var savedSDK = window.CtWebLogin; delete window.CtWebLogin;")
        let waiting = try result(js,"mount('attempt-a')")
        #expect(waiting["ok"] as? Bool == true && waiting["ready"] as? Bool == false)
        #expect(js.evaluateScript("fixtureMounts")?.toInt32() == 0)
        #expect(js.evaluateScript("document.body.children[0].style.display === undefined")?.toBool() == true)
        js.evaluateScript("window.CtWebLogin = savedSDK;")
        let ready = try result(js,"mount('attempt-a')")
        #expect(ready["ok"] as? Bool == true && ready["ready"] as? Bool == true)
        #expect(js.evaluateScript("fixtureMounts")?.toInt32() == 1)
        #expect(js.evaluateScript("fixtureProps.type")?.toString() == "page")
        #expect(js.evaluateScript("fixtureProps.parentNode.id")?.toString() == "alpaca-official-netease-login")
    }

    @Test func mountingHidesHomepageButLeavesNewOfficialVerificationAndConsentVisible() throws {
        let js = try context()
        _ = try result(js,"mount('attempt-a')")
        #expect(js.evaluateScript("document.body.children[0].style.display")?.toString() == "none")
        #expect(js.evaluateScript("document.body.children[1].style.display === undefined")?.toBool() == true)
        // Official SDK appends these after mount; they must not inherit a rule
        // hiding every body child or be relocated outside the real document.
        js.evaluateScript("var captcha = element('DIV'), consent = element('IFRAME'); document.body.appendChild(captcha); document.body.appendChild(consent);")
        _ = try result(js,"mount('attempt-a')")
        #expect(js.evaluateScript("captcha.style.display === undefined && consent.style.display === undefined")?.toBool() == true)
        #expect(js.evaluateScript("fixtureMounts")?.toInt32() == 1)
        #expect(js.evaluateScript("document.cookie")?.toString() == "synthetic-untouched=1")
        #expect(js.evaluateScript("fixtureNetwork")?.toInt32() == 0)
    }

    @Test func callbackExposesOnlyBooleanAndDoesNotForwardOfficialUserPayload() throws {
        let js = try context()
        _ = try result(js,"mount('attempt-a')")
        let pending = try result(js,"status('attempt-a')")
        #expect(pending["succeeded"] as? Bool == false)
        js.evaluateScript("fixtureProps.onSuccess({profile:{nickname:'private-person'},token:'private-token'});")
        let success = try result(js,"status('attempt-a')")
        #expect(success["succeeded"] as? Bool == true)
        #expect(Set(success.keys) == ["ok", "succeeded"])
        #expect(js.evaluateScript("JSON.stringify(window.__alpacaNeteaseLogin).includes('private')")?.toBool() == false)
    }

    @Test func staleCallbackCannotApproveReplacementAttempt() throws {
        let js = try context()
        _ = try result(js,"mount('attempt-a')")
        js.evaluateScript("var previousCallback = fixtureProps.onSuccess; delete window.__alpacaNeteaseLogin;")
        _ = try result(js,"mount('attempt-b')")
        js.evaluateScript("previousCallback({});")
        #expect(try result(js,"status('attempt-b')")["succeeded"] as? Bool == false)
        #expect(try result(js,"status('attempt-a')")["ok"] as? Bool == false)
        js.evaluateScript("fixtureProps.onSuccess({});")
        #expect(try result(js,"status('attempt-b')")["succeeded"] as? Bool == true)
    }

    @Test func unrelatedFrameOriginOrDocumentCannotMountOrSignalSuccess() throws {
        for mutation in ["location.origin = 'https://evil.invalid'", "location.pathname = '/login'", "window.top = {}", "document.contentType = 'application/json'"] {
            let js = try context()
            _ = try result(js,"mount('attempt-a')")
            js.evaluateScript("fixtureProps.onSuccess({}); " + mutation + ";")
            #expect(try result(js,"status('attempt-a')")["ok"] as? Bool == false)
            #expect(try result(js,"mount('attempt-a')")["ok"] as? Bool == false)
        }
    }

    @Test func officialComponentExceptionDoesNotExposeItsDetails() throws {
        let js = try context()
        js.evaluateScript("window.CtWebLogin.LoginModal = () => {throw new Error('private-callback-url');};")
        let failed = try result(js,"mount('attempt-a')")
        #expect(failed["ok"] as? Bool == false)
        #expect(failed.keys.count == 1)
    }

    @Test func approvalSignalAndRealAccountCookieAreBothRequired() throws {
        let real = try cookie()
        #expect(NeteaseQRAuthentication.confirmedSession([real], signalled:false) == nil)
        #expect(NeteaseQRAuthentication.confirmedSession([], signalled:true) == nil)
        #expect(NeteaseQRAuthentication.confirmedSession([try cookie("__csrf")], signalled:true) == nil)
        #expect(NeteaseQRAuthentication.confirmedSession([real], signalled:true) == [real])
    }

    @Test func wrongHostPathOrExpiredCookieCannotBecomeConnected() throws {
        let now = Date()
        let invalid = [
            try cookie(domain:".qq.com"), try cookie(domain:"interface.music.163.com"),
            try cookie(path:"/login"), try cookie(value:""),
            try cookie(expires:now.addingTimeInterval(-60)), try cookie("tracking")
        ]
        for value in invalid { #expect(NeteaseQRAuthentication.confirmedSession([value], signalled:true, now:now) == nil) }
    }

    @Test func unrelatedAndExpiredCookiesAreNotReturnedWithTheSession() throws {
        let valid = try cookie(), csrf = try cookie("__csrf"), unrelated = try cookie("tracking"), expired = try cookie("NMTID", expires:Date().addingTimeInterval(-60))
        let session = try #require(NeteaseQRAuthentication.confirmedSession([valid,csrf,unrelated,expired], signalled:true))
        #expect(Set(session.map(\.name)) == ["MUSIC_U", "__csrf"])
    }

    @Test func cancellingAnUnstartedAttemptIsIdempotentAndCannotProduceCookies() async {
        let service = NeteaseQRAuthentication()
        service.cancel(); service.cancel()
        #expect(service.visibleWebView == nil && !service.isLoading)
        await #expect(throws:CancellationError.self) { try await service.waitForCookies() }
    }

    private static let browser = #"""
    var fixtureMounts = 0, fixtureProps, fixtureNetwork = 0;
    var location = {origin:'https://music.163.com',pathname:'/'};
    function element(tagName) {return {tagName,style:{},children:[],appendChild(child){this.children.push(child);}};}
    var document = {contentType:'text/html',cookie:'synthetic-untouched=1',documentElement:element('HTML'),body:element('BODY'),createElement:element};
    document.body.appendChild(element('MAIN')); document.body.appendChild(element('SCRIPT'));
    var window = {CtWebLogin:{LoginModal(props){fixtureMounts++;fixtureProps=props;}}}; window.top = window;
    window.fetch = () => {fixtureNetwork++;throw new Error('unexpected fixture network');};
    """#
}
