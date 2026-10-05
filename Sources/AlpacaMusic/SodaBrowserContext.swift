import Foundation

/// Collects the current private browser's own account-request context. Values
/// remain inside that browser attempt and never cross the native result bridge.
enum SodaBrowserContext {
    static let script = #"""
    const state = window.__alpacaSodaLogin;
    if (!state || state.cancelled || !(state.controllers instanceof Map)) return {ok:false,failure:'browserContextCancelled'};
    if (location.origin !== 'https://api.qishui.com' || location.pathname !== '/' || !isSecureContext) return {ok:false,failure:'browserContextOrigin'};
    if (typeof state.accountSourceInfo === 'string' && state.accountSourceInfo.length > 0 && state.accountSourceInfo.length <= 24 * 1024) return {ok:true};

    const key = operationID + ':browserContext';
    const pending = new Set();
    let cancelled = false;
    const active = () => !cancelled && !state.cancelled && window.__alpacaSodaLogin === state;
    const controller = {abort:() => {
      cancelled = true;
      for (const reject of pending) reject({reason:'Cancelled'});
      pending.clear();
    }};
    state.controllers.set(key,controller);
    const bounded = work => new Promise((resolve,reject) => {
      let finished = false;
      let timer;
      const finish = (error,value) => {
        if (finished) return;
        finished = true;
        clearTimeout(timer);
        pending.delete(abort);
        if (error) reject(error); else resolve(value);
      };
      const abort = error => finish(error);
      pending.add(abort);
      if (!active()) {finish({reason:'Cancelled'});return;}
      timer = setTimeout(() => finish({reason:'Timeout'}),3000);
      Promise.resolve().then(work).then(
        value => finish(active() ? null : {reason:'Cancelled'},value),
        error => finish(active() ? error : {reason:'Cancelled'})
      );
    });
    const fallback = (error,value) => {
      if (error?.reason === 'Cancelled' || error?.reason === 'Timeout') throw error;
      return value;
    };

    const storageState = quota => {
      const storage = window.localStorage;
      const probe = '__alpaca_soda_storage_probe_' + crypto.randomUUID();
      let supported = false;
      let written = false;
      try {
        storage.setItem(probe,'1');
        supported = true;
        written = storage.getItem(probe) === '1';
      } catch (error) {
        supported = error instanceof DOMException &&
          (error.code === 22 || error.code === 1014 || error.name === 'QuotaExceededError' || error.name === 'NS_ERROR_DOM_QUOTA_REACHED') && storage.length !== 0;
      } finally {
        try {storage.removeItem(probe);} catch (_) {}
      }
      let size = 0;
      try {
        for (const name of Object.keys(storage)) size += (storage.getItem(name) ?? '').length;
      } catch (_) {size = -1;}
      const database = window.indexedDB ?? window.webkitIndexedDB ?? window.mozIndexedDB ?? window.OIndexedDB ?? window.msIndexedDB;
      const ua = navigator.userAgent;
      return {
        indexedDB:{
          idb:typeof database,open:database && typeof database.open,
          indexedDB:typeof window.indexedDB,IDBKeyRange:typeof window.IDBKeyRange,
          openDatabase:typeof window.openDatabase,
          isSafari:/(Safari|iPhone|iPad|iPod)/.test(ua) && !/Chrome/.test(ua) && !/BlackBerry/.test(navigator.platform),
          hasFetch:typeof window.fetch === 'function' && window.fetch.toString().includes('[native code')
        },
        localStorage:{isSupportLStorage:supported,size,write:written},
        storageQuotaStatus:quota
      };
    };
    const chromiumAutomationState = () => {
      for (const name of ['Array','Object','Promise','Proxy','Symbol','JSON']) {
        const marker = 'cdc_adoQpoasnfa76pfcZLmcfl_' + name;
        if (Object.prototype.hasOwnProperty.call(window,marker) || window[marker] === window[name]) return true;
      }
      return '$cdc_asdjflasutopfhvcZLmcfl_' in document;
    };
    const browserShellState = () => {
      try {
        const plugins = navigator.plugins;
        return !navigator.language || !Array.isArray(navigator.languages) || navigator.languages.length === 0 ||
          !plugins || plugins.length === 0 || !navigator.mimeTypes || navigator.mimeTypes.length === 0 ||
          Object.getPrototypeOf(plugins[0]) !== Plugin.prototype || Object.getPrototypeOf(plugins) !== PluginArray.prototype ||
          plugins[0][Symbol.toStringTag] !== 'Plugin';
      } catch (_) {return false;}
    };
    const graphicsState = () => {
      const canvas = document.createElement('canvas');
      let context;
      for (const name of ['webgl','experimental-webgl']) {
        try {context = canvas.getContext(name);} catch (_) {}
        if (context) break;
      }
      const extension = context?.getExtension('WEBGL_debug_renderer_info');
      if (!context || !extension) return {};
      return {vendor:context.getParameter(extension.UNMASKED_VENDOR_WEBGL),renderer:context.getParameter(extension.UNMASKED_RENDERER_WEBGL)};
    };
    const performanceState = () => {
      try {
        const first = performance.getEntries()[0] ?? {};
        return {
          timeOrigin:performance.timeOrigin,
          usedJSHeapSize:performance.memory?.usedJSHeapSize || 'unsupport',
          navigationTiming:{
            decodedBodySize:first.decodedBodySize,entryType:first.entryType,initiatorType:first.initiatorType,
            name:first.name,renderBlockingStatus:first.renderBlockingStatus,
            serverTiming:(first.serverTiming ?? []).map(entry => entry.name).join(','),
            guleStart:performance.getEntriesByName('script_glue_start')[0]?.startTime || 'none',
            guleDuration:performance.getEntriesByName('scriptGlueDuration')[0]?.duration || 'none'
          }
        };
      } catch (_) {return {};}
    };
    // This is the account protocol's byte encoding, not an identity or a
    // signature. Its legacy encoder ignores UTF-16 surrogate code units.
    const encodeContext = text => {
      const bytes = [];
      for (let index = 0; index < text.length; index++) {
        const code = text.charCodeAt(index);
        if (code <= 0x7f) bytes.push(code);
        else if (code <= 0x7ff) bytes.push(0xc0 | (code >> 6),0x80 | (code & 0x3f));
        else if (code < 0xd800 || code > 0xdfff) bytes.push(0xe0 | (code >> 12),0x80 | ((code >> 6) & 0x3f),0x80 | (code & 0x3f));
      }
      return bytes.map(byte => (byte ^ 5).toString(16)).join('');
    };
    try {
      const [quota,permissions] = await Promise.all([
        bounded(() => navigator.storage?.estimate ? navigator.storage.estimate() : {}).catch(error => fallback(error,{})),
        bounded(async () => {
          const permission = navigator.permissions?.query ? await navigator.permissions.query({name:'notifications'}) : undefined;
          return [{name:permission?.name || (permission ? 'notifications' : ''),state:permission?.state || ''}];
        }).catch(error => fallback(error,[]))
      ]);
      if (!active()) return {ok:false,failure:'browserContextCancelled'};
      const mediaPlay = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype,'play');
      const context = {
        hardwareConcurrency:navigator.hardwareConcurrency,
        webdriver:navigator.webdriver || /headless/i.test(navigator.userAgent),
        chromedriver:chromiumAutomationState(),shelldriver:browserShellState(),
        plugins:navigator.plugins?.length ?? 0,
        permissions,
        innerHeight:window.innerHeight,innerWidth:window.innerWidth,outerHeight:window.outerHeight,outerWidth:window.outerWidth,
        stoargeStatus:storageState({usage:quota?.usage,quota:quota?.quota,isPrivate:quota?.quota && quota.quota < 120000000}),
        webgl:graphicsState(),notificationPermission:'Notification' in window ? Notification.permission : 'none',
        performance:performanceState(),request_host:location.host,request_pathname:location.pathname,
        browser:{
          t:String(Date.now()).split('').reverse().join(''),
          // The SDK's supported useBitReport:false branch leaves this empty.
          bit_protocol:'',bit_helper:HTMLMediaElement.prototype.play.name !== 'play' || mediaPlay?.writable === false
        }
      };
      const json = JSON.stringify(context);
      if (new TextEncoder().encode(json).byteLength > 12 * 1024) return {ok:false,failure:'browserContextSize'};
      const encoded = encodeContext(json);
      if (encoded.length === 0 || encoded.length > 24 * 1024) return {ok:false,failure:'browserContextSize'};
      if (!active()) return {ok:false,failure:'browserContextCancelled'};
      state.accountSourceInfo = encoded;
      return {ok:true};
    } catch (error) {
      if (!active() || error?.reason === 'Cancelled') return {ok:false,failure:'browserContextCancelled'};
      return {ok:false,failure:error?.reason === 'Timeout' ? 'browserContextTimeout' : 'browserContextUnavailable'};
    } finally {
      state.controllers.delete(key);
    }
    """#
}
