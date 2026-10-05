import Foundation
import JavaScriptCore
import Testing
@testable import AlpacaMusic

/// Runs the production async script with synthetic fetch replies. JavaScriptCore
/// supplies the language runtime; the small browser adapters never use a network.
@Suite @MainActor struct SodaWebIdentityBootstrapTests {
    private struct Reply {
        var body: String
        var status = 200
        var cancelDuringFetch = false
        var rejectFetch = false

        var object: [String: Any] {
            ["body": body, "status": status, "cancelDuringFetch": cancelDuringFetch, "rejectFetch": rejectFetch]
        }
    }

    private struct Execution {
        let result: [String: Any]
        let requests: [[String: Any]]
        let resultJSON: String
        let controllers: Int
        let timers: Int

        var paths: [String] { requests.compactMap { $0["path"] as? String } }
        var failure: String? { result["failure"] as? String }
        var succeeded: Bool { result["ok"] as? Bool == true }
    }

    private func execute(_ replies: [Reply], cancelled: Bool = false) throws -> Execution {
        let context = try #require(JSContext())
        let fixtures = try JSONSerialization.data(withJSONObject: replies.map(\.object))
        context.setObject(String(decoding: fixtures, as: UTF8.self), forKeyedSubscript: "fixtureJSON" as NSString)
        context.setObject(cancelled, forKeyedSubscript: "initialCancelled" as NSString)
        context.setObject("synthetic-operation", forKeyedSubscript: "operationID" as NSString)
        context.evaluateScript(Self.browserAdapters)
        #expect(context.exception == nil)
        let body = "(async function() {\n" + SodaWebIdentityBootstrap.script + "\n})().then(function(value) { testResult = value; testFinished = true; }, function() { testUncaught = true; testFinished = true; });"
        context.evaluateScript(body)
        // Promise jobs normally drain before evaluateScript returns. Additional
        // empty turns also support runtimes that defer jobs to the next API entry.
        for _ in 0..<12 where context.objectForKeyedSubscript("testFinished")?.toBool() != true {
            context.evaluateScript("void 0;")
        }
        #expect(context.exception == nil)
        #expect(context.objectForKeyedSubscript("testUncaught")?.toBool() == false)
        let finished = context.objectForKeyedSubscript("testFinished")?.toBool() == true
        try #require(finished, "Production identity script did not resolve its synthetic Promise chain")
        let json = try #require(context.evaluateScript("JSON.stringify({result:testResult,requests:testRequests,controllers:window.__alpacaSodaLogin.controllers.size,timers:testTimers.size})")?.toString())
        let snapshot = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let result = try #require(snapshot["result"] as? [String: Any])
        let requests = try #require(snapshot["requests"] as? [[String: Any]])
        let resultData = try JSONSerialization.data(withJSONObject: result, options: .sortedKeys)
        return Execution(result: result, requests: requests, resultJSON: String(decoding: resultData, as: UTF8.self),
                         controllers: try #require(snapshot["controllers"] as? Int),
                         timers: try #require(snapshot["timers"] as? Int))
    }

    @Test func acceptedIdentitySkipsRegistration() throws {
        let run = try execute([.init(body: #"{"status_code":0}"#)])
        #expect(run.succeeded && run.failure == nil)
        #expect(run.paths == ["/ttwid/check/"])
        #expect(run.controllers == 0 && run.timers == 0)
    }

    @Test func missingIdentityRegistersAndRechecksWithoutReturningMigrationData() throws {
        let secret = "synthetic-private-migration-data"
        let run = try execute([
            .init(body: #"{"status_code":1002,"migrate_info":{"migrate_data":"synthetic-private-migration-data","migrate_priority":3}}"#),
            .init(body: #"{"status_code":0,"migrate_data":"synthetic-private-registration-data"}"#),
            .init(body: #"{"status_code":0,"migrate_data":"synthetic-private-recheck-data"}"#)
        ])
        #expect(run.succeeded && run.failure == nil)
        #expect(run.paths == ["/ttwid/check/", "/ttwid/register/", "/ttwid/check/"])
        let registration = try #require(run.requests[1]["body"] as? [String: Any])
        let migration = try #require(registration["migrate_info"] as? [String: Any])
        #expect(migration["migrate_data"] as? String == secret)
        #expect(migration["migrate_priority"] as? Int == 3)
        #expect(run.result.keys.count == 1 && run.result["ok"] as? Bool == true)
        #expect(!run.resultJSON.contains("migrate") && !run.resultJSON.contains("synthetic-private"))
        #expect(run.requests.allSatisfy { $0["credentials"] as? String == "same-origin" && $0["redirect"] as? String == "error" })
        #expect(run.controllers == 0 && run.timers == 0)
    }

    @Test func checkFailureDoesNotGuessThatIdentityIsUsable() throws {
        let run = try execute([.init(body: #"{"status_code":1001,"migrate_data":"synthetic-private-error-data"}"#)])
        #expect(!run.succeeded && run.failure == "webIdentityCheckStatus")
        #expect(run.paths == ["/ttwid/check/"])
        #expect(!run.resultJSON.contains("synthetic-private"))
        #expect(run.controllers == 0 && run.timers == 0)
    }

    @Test func registrationFailureStopsBeforeRecheck() throws {
        let run = try execute([
            .init(body: #"{"status_code":1002,"migrate_info":{"migrate_data":"synthetic-private-migration-data"}}"#),
            .init(body: #"{"status_code":1003,"migrate_data":"synthetic-private-error-data"}"#)
        ])
        #expect(!run.succeeded && run.failure == "webIdentityRegisterStatus")
        #expect(run.paths == ["/ttwid/check/", "/ttwid/register/"])
        #expect(!run.resultJSON.contains("migrate") && !run.resultJSON.contains("synthetic-private"))
        #expect(run.controllers == 0 && run.timers == 0)
    }

    @Test func recheckFailureCannotPublishSuccessfulIdentity() throws {
        let run = try execute([
            .init(body: #"{"status_code":1002,"migrate_info":{}}"#),
            .init(body: #"{"status_code":0}"#),
            .init(body: #"{"status_code":1002,"migrate_data":"synthetic-private-error-data"}"#)
        ])
        #expect(!run.succeeded && run.failure == "webIdentityRecheckStatus")
        #expect(run.paths == ["/ttwid/check/", "/ttwid/register/", "/ttwid/check/"])
        #expect(!run.resultJSON.contains("synthetic-private"))
        #expect(run.controllers == 0 && run.timers == 0)
    }

    @Test func cancellationBeforeOrDuringFetchCannotRegisterOrReportSuccess() throws {
        let before = try execute([], cancelled: true)
        #expect(!before.succeeded && before.failure == "webIdentityCancelled")
        #expect(before.requests.isEmpty && before.controllers == 0 && before.timers == 0)

        let during = try execute([.init(body: #"{"status_code":1002,"migrate_info":{}}"#, cancelDuringFetch: true)])
        #expect(!during.succeeded && during.failure == "webIdentityCheckCancelled")
        #expect(during.paths == ["/ttwid/check/"])
        #expect(during.controllers == 0 && during.timers == 0)
    }

    @Test func transportAndMalformedResponsesReturnOnlyFixedFailureLabels() throws {
        for (reply, expected) in [
            (Reply(body: #"{"status_code":0}"#, status: 503), "webIdentityCheckHTTP"),
            (Reply(body: #"{"status_code":"0","migrate_data":"synthetic-private-error-data"}"#), "webIdentityCheckResponse"),
            (Reply(body: "synthetic-private-malformed-response"), "webIdentityCheckResponse"),
            (Reply(body: "synthetic-private-network-error", rejectFetch: true), "webIdentityCheckNetwork")
        ] {
            let run = try execute([reply])
            #expect(!run.succeeded && run.failure == expected)
            #expect(run.paths == ["/ttwid/check/"])
            #expect(!run.resultJSON.contains("synthetic-private") && !run.resultJSON.contains("migrate"))
            #expect(run.controllers == 0 && run.timers == 0)
        }
    }

    private static let browserAdapters = #"""
    var window = {__alpacaSodaLogin:{controllers:new Map(),cancelled:initialCancelled}};
    var location = {origin:'https://api.qishui.com',pathname:'/'};
    var isSecureContext = true;
    var testReplies = JSON.parse(fixtureJSON);
    var testRequests = [];
    var testResult, testFinished = false, testUncaught = false;
    var testTimers = new Map(), nextTimer = 0;
    function setTimeout(callback,delay) {const id = ++nextTimer;testTimers.set(id,{callback,delay});return id;}
    function clearTimeout(id) {testTimers.delete(id);}
    class AbortController {
      constructor() {this.signal = {aborted:false};}
      abort() {this.signal.aborted = true;}
    }
    class URL {
      constructor(value,base) {
        this.href = String(value).startsWith('/') ? String(base)+String(value) : String(value);
        const match = this.href.match(/^(https:\/\/[^/?#]+)([^?#]*)/);
        if (!match) throw new Error('Invalid synthetic URL');
        this.origin = match[1];this.pathname = match[2] || '/';
      }
    }
    class TextEncoder {
      encode(value) {
        const bytes = [];
        for (const character of String(value)) {
          const point = character.codePointAt(0);
          if (point <= 0x7f) bytes.push(point);
          else if (point <= 0x7ff) bytes.push(0xc0|(point>>6),0x80|(point&0x3f));
          else if (point <= 0xffff) bytes.push(0xe0|(point>>12),0x80|((point>>6)&0x3f),0x80|(point&0x3f));
          else bytes.push(0xf0|(point>>18),0x80|((point>>12)&0x3f),0x80|((point>>6)&0x3f),0x80|(point&0x3f));
        }
        return Uint8Array.from(bytes);
      }
    }
    class TextDecoder {
      decode(bytes) {return decodeURIComponent(Array.from(bytes,b=>'%'+b.toString(16).padStart(2,'0')).join(''));}
    }
    async function fetch(address,options) {
      const url = new URL(address);
      testRequests.push({path:url.pathname,body:JSON.parse(options.body),credentials:options.credentials,redirect:options.redirect});
      const reply = testReplies.shift();
      if (!reply) throw new Error('Unexpected synthetic request');
      if (reply.rejectFetch) throw new Error(reply.body);
      if (reply.cancelDuringFetch) window.__alpacaSodaLogin.cancelled = true;
      const bytes = new TextEncoder().encode(reply.body);
      let delivered = false;
      return {
        url:address,status:reply.status,headers:{get:()=>null},
        body:{getReader:()=>({
          read:async()=>{if(delivered)return {done:true};delivered=true;return {done:false,value:bytes};},
          cancel:async()=>{},releaseLock:()=>{}
        })}
      };
    }
    """#
}
