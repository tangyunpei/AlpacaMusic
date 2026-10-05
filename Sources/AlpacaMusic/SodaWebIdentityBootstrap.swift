import Foundation

/// The consumer client's ordinary WebID bootstrap, confined to the fresh
/// browser session. A WebID is never substituted for native device/install IDs.
enum SodaWebIdentityBootstrap {
    /// Called after the official SDK has initialized __alpacaSodaLogin. Only
    /// fixed failure labels cross the bridge; response identity data stays here.
    static let script = #"""
    const state = window.__alpacaSodaLogin;
    if (!state || state.cancelled || !(state.controllers instanceof Map)) return {ok:false,failure:'webIdentityCancelled'};
    if (location.origin !== 'https://api.qishui.com' || location.pathname !== '/' || !isSecureContext) return {ok:false,failure:'webIdentityOrigin'};
    const responseLimit = 64 * 1024;
    const deadline = Date.now() + 10000;
    const base = {aid:386088,service:'api.qishui.com',host:'https://api.qishui.com',unionHost:'',union:false,needFid:false};
    const checkBody = {...base,fid:'',migrate_priority:0};
    const knownReasons = new Set(['HTTP','Response','Size','Status','Network','Timeout','Cancelled','Origin']);
    let stage = 'Check';
    const request = async (path, payload) => {
      if (state.cancelled) throw {reason:'Cancelled'};
      const remaining = deadline - Date.now();
      if (remaining <= 0) throw {reason:'Timeout'};
      const encoded = JSON.stringify(payload);
      if (new TextEncoder().encode(encoded).byteLength > responseLimit) throw {reason:'Size'};
      const controller = new AbortController();
      const key = operationID + ':webIdentity:' + stage;
      state.controllers.set(key,controller);
      let timedOut = false;
      const timer = setTimeout(() => {timedOut = true;controller.abort();},Math.min(3000,remaining));
      let reader;
      try {
        const response = await fetch(new URL(path,location.origin).href,{
          method:'POST',
          headers:{'Accept':'application/json, text/plain, */*','Content-Type':'application/json'},
          body:encoded,
          credentials:'same-origin',mode:'same-origin',redirect:'error',cache:'no-store',signal:controller.signal
        });
        if (state.cancelled) throw {reason:'Cancelled'};
        const actualURL = new URL(response.url);
        if (actualURL.origin !== location.origin || actualURL.pathname !== path) throw {reason:'Origin'};
        if (response.status < 200 || response.status >= 300) {controller.abort();throw {reason:'HTTP'};}
        const contentLength = Number(response.headers.get('Content-Length'));
        if (Number.isFinite(contentLength) && contentLength > responseLimit) {controller.abort();throw {reason:'Size'};}
        const chunks = [];
        let size = 0;
        if (response.body) {
          reader = response.body.getReader();
          while (true) {
            const part = await reader.read();
            if (part.done) break;
            size += part.value.byteLength;
            if (size > responseLimit) {controller.abort();await reader.cancel();throw {reason:'Size'};}
            chunks.push(part.value);
          }
        }
        if (state.cancelled) throw {reason:'Cancelled'};
        const bytes = new Uint8Array(size);
        let offset = 0;
        for (const chunk of chunks) {bytes.set(chunk,offset);offset += chunk.byteLength;}
        let result;
        try {result = JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));}
        catch (_) {throw {reason:'Response'};}
        if (!result || typeof result !== 'object' || Array.isArray(result) || typeof result.status_code !== 'number' || !Number.isSafeInteger(result.status_code)) throw {reason:'Response'};
        return result;
      } catch (error) {
        if (state.cancelled) throw {reason:'Cancelled'};
        if (timedOut) throw {reason:'Timeout'};
        if (knownReasons.has(error?.reason)) throw {reason:error.reason};
        throw {reason:'Network'};
      } finally {
        clearTimeout(timer);
        state.controllers.delete(key);
        try {reader?.releaseLock();} catch (_) {}
      }
    };
    try {
      const checked = await request('/ttwid/check/',checkBody);
      if (checked.status_code === 0) return {ok:true};
      // The shipped client registers only for >1001. Do not guess that other
      // returned codes establish a usable identity or retry them indefinitely.
      if (checked.status_code <= 1001) return {ok:false,failure:'webIdentityCheckStatus'};
      stage = 'Register';
      const registered = await request('/ttwid/register/',{...base,migrate_info:checked.migrate_info,fid:''});
      if (registered.status_code !== 0) return {ok:false,failure:'webIdentityRegisterStatus'};
      stage = 'Recheck';
      const verified = await request('/ttwid/check/',checkBody);
      if (verified.status_code !== 0) return {ok:false,failure:'webIdentityRecheckStatus'};
      // Server acceptance in the same browser jar is stronger evidence than
      // document.cookie, which correctly hides an HttpOnly WebID cookie.
      return {ok:true};
    } catch (error) {
      const reason = knownReasons.has(error?.reason) ? error.reason : 'Network';
      return {ok:false,failure:'webIdentity'+stage+reason};
    }
    """#
}
