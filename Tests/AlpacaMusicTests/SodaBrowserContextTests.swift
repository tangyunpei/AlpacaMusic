import Foundation
import JavaScriptCore
import Testing
@testable import AlpacaMusic

/// Executes the production collector with ordinary synthetic browser surfaces.
/// No browser, network, external storage or application login is started.
@Suite @MainActor struct SodaBrowserContextTests {
    private struct Run {
        let result: [String: Any]
        let context: [String: Any]?
        let snapshot: [String: Any]
        let resultJSON: String
        var succeeded: Bool { result["ok"] as? Bool == true }
        var failure: String? { result["failure"] as? String }
    }

    private func execute(mode: String = "normal", twice: Bool = false) throws -> Run {
        let js = try #require(JSContext())
        js.setObject(mode, forKeyedSubscript:"fixtureMode" as NSString)
        js.setObject(twice, forKeyedSubscript:"fixtureTwice" as NSString)
        js.evaluateScript(Self.browser)
        #expect(js.exception == nil)
        let script = "async function collect(operationID) {\n" + SodaBrowserContext.script + "\n}\n" + #"""
        (async function() {
          testResult = await collect('synthetic-operation');
          testFirstInfo = window.__alpacaSodaLogin.accountSourceInfo ?? null;
          if (fixtureTwice) {
            navigator.hardwareConcurrency = 99;
            window.innerHeight = 111;
            testResult = await collect('synthetic-second-operation');
          }
          testFinished = true;
        })().catch(function() {testUncaught = true;testFinished = true;});
        """#
        js.evaluateScript(script)
        for _ in 0..<32 where js.objectForKeyedSubscript("testFinished")?.toBool() != true { js.evaluateScript("void 0;") }
        #expect(js.exception == nil)
        #expect(js.objectForKeyedSubscript("testUncaught")?.toBool() == false)
        let finished = js.objectForKeyedSubscript("testFinished")?.toBool() == true
        try #require(finished, "Production browser collector did not resolve its synthetic Promise chain")
        let json = try #require(js.evaluateScript("JSON.stringify({result:testResult,encoded:window.__alpacaSodaLogin.accountSourceInfo??null,first:testFirstInfo,estimates:testEstimates,permissions:testPermissions,timers:testTimers.size,controllers:window.__alpacaSodaLogin.controllers.size,storage:window.localStorage,storageOps:testStorageOps,navigation:testNavigation,network:testNetwork})")?.toString())
        let snapshot = try #require(try JSONSerialization.jsonObject(with:Data(json.utf8)) as? [String: Any])
        let result = try #require(snapshot["result"] as? [String: Any])
        let decoded = try (snapshot["encoded"] as? String).map(Self.decode)
        let safeJSON = try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys])
        return Run(result:result, context:decoded, snapshot:snapshot, resultJSON:String(decoding:safeJSON,as:UTF8.self))
    }

    private static func decode(_ encoded: String) throws -> [String: Any] {
        #expect(encoded.count % 2 == 0)
        let characters = Array(encoded)
        var bytes: [UInt8] = []
        for index in stride(from:0,to:characters.count,by:2) {
            let hex = String(characters[index...index + 1])
            bytes.append(try #require(UInt8(hex,radix:16)) ^ 5)
        }
        return try #require(try JSONSerialization.jsonObject(with:Data(bytes)) as? [String: Any])
    }

    private func checkClean(_ run: Run) throws {
        #expect(run.snapshot["controllers"] as? Int == 0)
        #expect(run.snapshot["timers"] as? Int == 0)
        #expect(run.snapshot["navigation"] as? Int == 0)
        #expect(run.snapshot["network"] as? Int == 0)
        let storage = try #require(run.snapshot["storage"] as? [String: String])
        #expect(storage == ["preserved":"original-browser-state"])
        let operations = try #require(run.snapshot["storageOps"] as? [[String: String]])
        #expect(operations.allSatisfy { ($0["key"] ?? "").hasPrefix("__alpaca_soda_storage_probe_") })
        #expect(operations.filter { $0["kind"] == "set" }.count == operations.filter { $0["kind"] == "remove" }.count)
    }

    @Test func ownBrowserValuesAreEncodedOnceAndStayInsideBrowserState() throws {
        let run = try execute(twice:true)
        #expect(run.succeeded && run.result.keys.count == 1)
        #expect(run.snapshot["encoded"] as? String == run.snapshot["first"] as? String)
        #expect(run.snapshot["estimates"] as? Int == 1 && run.snapshot["permissions"] as? Int == 1)
        let info = try #require(run.context)
        #expect(info["hardwareConcurrency"] as? Int == 6 && info["innerHeight"] as? Int == 720)
        #expect(info["request_host"] as? String == "api.qishui.com" && info["request_pathname"] as? String == "/")
        #expect(info["webdriver"] as? Bool == true && info["chromedriver"] as? Bool == true && info["shelldriver"] as? Bool == true)
        let graphics = try #require(info["webgl"] as? [String: String])
        #expect(graphics["vendor"] == "synthetic-own-测试" && graphics["renderer"] == "own-renderer")
        let browser = try #require(info["browser"] as? [String: Any])
        #expect(browser["bit_protocol"] as? String == "" && browser["bit_helper"] as? Bool == true)
        #expect(!run.resultJSON.contains("synthetic-own") && !run.resultJSON.contains("api.qishui.com") && !run.resultJSON.contains("accountSourceInfo"))
        let operations = try #require(run.snapshot["storageOps"] as? [[String: String]])
        #expect(operations.count == 2)
        try checkClean(run)
    }

    @Test func cancellationBeforeDuringOrAfterAwaitCannotPublishBrowserContext() throws {
        for mode in ["before", "during", "after"] {
            let run = try execute(mode:mode)
            #expect(!run.succeeded && run.failure == "browserContextCancelled")
            #expect(run.context == nil)
            try checkClean(run)
        }
    }

    @Test func collectorFailureReturnsOnlyFixedReasonWithoutUnderlyingDetails() throws {
        let run = try execute(mode:"unavailable")
        #expect(!run.succeeded && run.failure == "browserContextUnavailable")
        #expect(run.context == nil && !run.resultJSON.contains("synthetic-private-error"))
        try checkClean(run)
    }

    @Test func oversizedOwnDataCannotLeavePartialCacheOrStorageChanges() throws {
        let run = try execute(mode:"large")
        #expect(!run.succeeded && run.failure == "browserContextSize")
        #expect(run.context == nil)
        #expect(!run.resultJSON.contains("own-renderer"))
        try checkClean(run)
    }

    private static let browser = #"""
    var testResult, testFirstInfo, testFinished = false, testUncaught = false;
    var testEstimates = 0, testPermissions = 0, testNavigation = 0, testNetwork = 0;
    var testStorageOps = [], testTimers = new Map(), testTimerID = 0;
    function setTimeout(callback,delay) {const id = ++testTimerID;testTimers.set(id,{callback,delay});return id;}
    function clearTimeout(id) {testTimers.delete(id);}
    var window = {__alpacaSodaLogin:{controllers:new Map(),cancelled:fixtureMode==='before'},innerHeight:720,innerWidth:1024,outerHeight:800,outerWidth:1100,Array,Object,Promise,Proxy,Symbol,JSON};
    var location = {origin:'https://api.qishui.com',host:'api.qishui.com',pathname:'/'};
    Object.defineProperty(location,'href',{get:()=>location.origin+'/',set:()=>testNavigation++});
    window.location = location;
    window.open = () => {testNavigation++;throw new Error('Unexpected synthetic navigation');};
    var isSecureContext = true;
    var crypto = {randomUUID:()=> 'synthetic-own-key'};
    var localStorage = {preserved:'original-browser-state'};
    Object.defineProperties(localStorage,{
      setItem:{value:function(key,value){testStorageOps.push({kind:'set',key});this[key]=String(value);}},
      getItem:{value:function(key){return this[key]??null;}},
      removeItem:{value:function(key){testStorageOps.push({kind:'remove',key});delete this[key];}},
      length:{get:function(){return Object.keys(this).length;}}
    });
    window.localStorage = localStorage;
    window.indexedDB = {open:function(){}};
    window.IDBKeyRange = function(){};
    window.fetch = function(){testNetwork++;throw new Error('Unexpected synthetic network');};
    window.cdc_adoQpoasnfa76pfcZLmcfl_Array = Array;
    var navigator = {
      hardwareConcurrency:6,webdriver:true,userAgent:'Synthetic Browser',platform:'Synthetic',
      language:'zh',languages:['zh'],plugins:[],mimeTypes:[],
      storage:{estimate:async function(){testEstimates++;if(fixtureMode==='during')window.__alpacaSodaLogin.cancelled=true;return {usage:789,quota:150000000};}},
      permissions:{query:async function(){testPermissions++;return {name:'notifications',get state(){if(fixtureMode==='after')window.__alpacaSodaLogin.cancelled=true;return 'prompt';}};}}
    };
    if(fixtureMode==='unavailable')Object.defineProperty(navigator,'hardwareConcurrency',{get:()=>{throw new Error('synthetic-private-error');}});
    class HTMLMediaElement {}
    HTMLMediaElement.prototype.play = function fixturePlay(){};
    var performance = {timeOrigin:1200,memory:{usedJSHeapSize:456},getEntries:()=>[{decodedBodySize:42,entryType:'navigation',initiatorType:'navigation',name:'https://api.qishui.com/',serverTiming:[]}],getEntriesByName:()=>[]};
    var document = {createElement:function(name){if(name!=='canvas')throw new Error('Unexpected synthetic element');return {getContext:()=>({getExtension:()=>({UNMASKED_VENDOR_WEBGL:1,UNMASKED_RENDERER_WEBGL:2}),getParameter:key=>key===1?(fixtureMode==='large'?'x'.repeat(13000):'synthetic-own-测试'):'own-renderer'})};}};
    class TextEncoder {
      encode(value){return Uint8Array.from(Array.from(unescape(encodeURIComponent(String(value))),character=>character.charCodeAt(0)));}
    }
    """#
}
