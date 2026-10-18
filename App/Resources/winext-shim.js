// WinBrowse WebExtension runtime: a chrome.* implementation backed by the native host.
// Evaluated once per JS world (an extension's content world, or an extension page / background page).
// The host calls __winextInstall(config) right after this file; config = {id, ctx, manifest, messages, uiLang, tabId}.
(function () {
  if (globalThis.__winextInstall) return;

  globalThis.__winextInstall = function (cfg) {
    if (globalThis.__winext) return;
    const EXT = cfg.id;
    const CTX = cfg.ctx;            // 'content' | 'background' | 'page'
    const BASE = 'winext://' + EXT + '/';
    const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.winext;

    // ---- bridge ---------------------------------------------------------------------------------
    async function call(type, data) {
      if (!handler) throw new Error('Extension context invalidated.');
      const reply = await handler.postMessage({ type, ext: EXT, data: JSON.stringify(data === undefined ? null : data) });
      if (reply == null || reply === '') return undefined;
      const r = JSON.parse(reply);
      if (r && r.__error) throw new Error(r.__error);
      return r === null ? undefined : r;
    }
    function fireAndForget(type, data) { call(type, data).catch(() => {}); }

    // ---- helpers --------------------------------------------------------------------------------
    let lastErrorValue;
    function withCallback(promise, cb) {
      if (typeof cb !== 'function') return promise;
      promise.then(
        (v) => { try { cb(v); } catch (e) { console.error(e); } },
        (e) => {
          lastErrorValue = { message: (e && e.message) || String(e) };
          try { cb(); } catch (err) { console.error(err); } finally { lastErrorValue = undefined; }
        });
      return undefined;
    }
    function api(fn) {
      return function (...args) {
        let cb;
        if (args.length && typeof args[args.length - 1] === 'function') cb = args.pop();
        let p;
        try { p = Promise.resolve(fn.apply(null, args)); } catch (e) { p = Promise.reject(e); }
        return withCallback(p, cb);
      };
    }
    class WEvent {
      constructor() { this._l = []; }
      addListener(f) { if (typeof f === 'function' && !this._l.includes(f)) this._l.push(f); }
      removeListener(f) { this._l = this._l.filter((x) => x !== f); }
      hasListener(f) { return this._l.includes(f); }
      hasListeners() { return this._l.length > 0; }
      _fire(...a) { for (const f of this._l.slice()) { try { f(...a); } catch (e) { console.error(e); } } }
    }
    const noopEvent = () => new WEvent();
    const clone = (v) => (v === undefined ? undefined : JSON.parse(JSON.stringify(v)));

    // ---- i18n -----------------------------------------------------------------------------------
    const messages = cfg.messages || {};
    function getMessage(name, subs) {
      if (name == null) return '';
      name = String(name);
      const special = { '@@extension_id': EXT, '@@ui_locale': (cfg.uiLang || 'en').replace('-', '_'), '@@bidi_dir': 'ltr', '@@bidi_reversed_dir': 'rtl', '@@bidi_start_edge': 'left', '@@bidi_end_edge': 'right' };
      if (name in special) return special[name];
      const m = messages[name] || messages[name.toLowerCase()];
      if (!m) return '';
      if (subs != null && !Array.isArray(subs)) subs = [subs];
      subs = (subs || []).map(String);
      let text = String(m.message);
      const ph = m.placeholders || {};
      text = text.replace(/\$([A-Za-z0-9_@]+)\$/g, (all, key) => {
        const p = ph[key] || ph[key.toLowerCase()];
        if (!p) return all;
        return String(p.content).replace(/\$(\d)/g, (a, d) => subs[+d - 1] ?? '');
      });
      text = text.replace(/\$(\d)/g, (a, d) => subs[+d - 1] ?? '').replace(/\$\$/g, '$');
      return text;
    }

    // ---- storage --------------------------------------------------------------------------------
    const storageOnChanged = new WEvent();
    function makeArea(area) {
      const ev = new WEvent();
      const a = {
        get: api(async (keys) => {
          let list = null, defaults = null;
          if (keys == null) list = null;
          else if (typeof keys === 'string') list = [keys];
          else if (Array.isArray(keys)) list = keys.map(String);
          else if (typeof keys === 'object') { defaults = keys; list = Object.keys(keys); }
          const got = (await call('storage.get', { area, keys: list })) || {};
          if (defaults) for (const k of Object.keys(defaults)) if (!(k in got) && defaults[k] !== undefined) got[k] = clone(defaults[k]);
          return got;
        }),
        getKeys: api(async () => Object.keys((await call('storage.get', { area, keys: null })) || {})),
        set: api(async (items) => { await call('storage.set', { area, items: clone(items || {}) }); }),
        remove: api(async (keys) => { await call('storage.remove', { area, keys: typeof keys === 'string' ? [keys] : (keys || []) }); }),
        clear: api(async () => { await call('storage.clear', { area }); }),
        getBytesInUse: api(async () => 0),
        setAccessLevel: api(async () => {}),
        onChanged: ev,
        QUOTA_BYTES: 10485760,
        QUOTA_BYTES_PER_ITEM: 8192,
        MAX_ITEMS: 512,
        MAX_WRITE_OPERATIONS_PER_HOUR: 1800,
        MAX_WRITE_OPERATIONS_PER_MINUTE: 120,
      };
      a._ev = ev;
      return a;
    }
    const storage = { local: makeArea('local'), sync: makeArea('sync'), session: makeArea('session'), managed: makeArea('managed'), onChanged: storageOnChanged };

    // ---- messaging ------------------------------------------------------------------------------
    const onMessage = new WEvent();
    const onConnect = new WEvent();
    const ports = new Map();

    function deliverMessage(msg, sender) {
      return new Promise((resolve) => {
        const ls = onMessage._l.slice();
        if (!ls.length) return resolve({ handled: false });
        let done = false, keep = false;
        const sendResponse = (r) => { if (!done) { done = true; resolve({ handled: true, response: clone(r) }); } };
        for (const f of ls) {
          let ret;
          try { ret = f(clone(msg), sender, sendResponse); } catch (e) { console.error(e); }
          if (ret === true) keep = true;
          else if (ret && typeof ret.then === 'function') { keep = true; ret.then(sendResponse, () => sendResponse(undefined)); }
        }
        if (!keep && !done) resolve({ handled: true, response: undefined, sync: true });
      });
    }

    function parseSendArgs(args) {
      // sendMessage([extensionId], message, [options])
      if (args.length >= 3) return args[1];
      if (args.length === 2) {
        if (typeof args[0] === 'string' && args[0] === EXT) return args[1];
        return args[0];
      }
      return args[0];
    }

    function makePort(portId, name, sender) {
      const port = {
        name: name || '',
        sender,
        onMessage: new WEvent(),
        onDisconnect: new WEvent(),
        postMessage(m) {
          if (port._closed) throw new Error('Attempting to use a disconnected port object');
          fireAndForget('port.post', { portId, msg: clone(m) });
        },
        disconnect() {
          if (port._closed) return;
          port._closed = true; ports.delete(portId);
          fireAndForget('port.disconnect', { portId });
        },
      };
      ports.set(portId, port);
      return port;
    }
    const newId = () => Math.random().toString(36).slice(2) + Date.now().toString(36);

    function connect(...args) {
      let info = args.find((a) => a && typeof a === 'object') || {};
      const portId = newId();
      const port = makePort(portId, info.name, undefined);
      call('runtime.connect', { portId, name: info.name || '' }).then((r) => {
        if (!r || !r.connected) setTimeout(() => { if (!port._closed) { port._closed = true; ports.delete(portId); port.onDisconnect._fire(port); } }, 250);
      }, () => {});
      return port;
    }

    // ---- runtime --------------------------------------------------------------------------------
    const manifest = cfg.manifest || {};
    const runtime = {
      id: EXT,
      get lastError() { return lastErrorValue; },
      getURL: (p) => BASE + String(p || '').replace(/^\//, ''),
      getManifest: () => clone(manifest),
      sendMessage: api(async (...args) => {
        const msg = parseSendArgs(args);
        const r = await call('runtime.sendMessage', { msg: clone(msg) });
        if (!r || !r.handled) throw new Error('Could not establish connection. Receiving end does not exist.');
        return r.response;
      }),
      connect,
      onMessage,
      onConnect,
      onMessageExternal: noopEvent(),
      onConnectExternal: noopEvent(),
      onInstalled: new WEvent(),
      onStartup: new WEvent(),
      onSuspend: noopEvent(),
      onUpdateAvailable: noopEvent(),
      openOptionsPage: api(async () => { await call('runtime.openOptionsPage', {}); }),
      getPlatformInfo: api(async () => ({ os: 'ios', arch: 'arm', nacl_arch: 'arm' })),
      getBrowserInfo: api(async () => ({ name: 'WinBrowse', vendor: 'WinBrowse', version: '1.0' })),
      setUninstallURL: api(async () => {}),
      reload: () => {},
      requestUpdateCheck: api(async () => ['no_update']),
      getContexts: api(async () => []),
      sendNativeMessage: api(async () => { throw new Error('Native messaging is not supported.'); }),
    };

    // ---- tabs / windows -------------------------------------------------------------------------
    const tabs = {
      TAB_ID_NONE: -1,
      query: api(async (q) => (await call('tabs.query', q || {})) || []),
      get: api(async (tabId) => { const t = await call('tabs.get', { tabId }); if (!t) throw new Error('No tab with id: ' + tabId); return t; }),
      getCurrent: api(async () => (CTX === 'page' && cfg.tabId >= 0 ? await call('tabs.get', { tabId: cfg.tabId }) : undefined)),
      create: api(async (p) => await call('tabs.create', p || {})),
      update: api(async (...a) => { const tabId = typeof a[0] === 'number' ? a[0] : undefined; const p = typeof a[0] === 'number' ? a[1] : a[0]; return await call('tabs.update', { tabId, props: p || {} }); }),
      remove: api(async (ids) => { await call('tabs.remove', { ids: Array.isArray(ids) ? ids : [ids] }); }),
      reload: api(async (tabId) => { await call('tabs.reload', { tabId }); }),
      sendMessage: api(async (tabId, msg, opts) => {
        const r = await call('tabs.sendMessage', { tabId, msg: clone(msg), frameId: opts && opts.frameId });
        if (!r || !r.handled) throw new Error('Could not establish connection. Receiving end does not exist.');
        return r.response;
      }),
      connect: (tabId, info) => {
        const portId = newId();
        const port = makePort(portId, info && info.name, undefined);
        call('tabs.connect', { portId, tabId, name: (info && info.name) || '' }).then((r) => {
          if (!r || !r.connected) setTimeout(() => { if (!port._closed) { port._closed = true; ports.delete(portId); port.onDisconnect._fire(port); } }, 250);
        }, () => {});
        return port;
      },
      executeScript: api(async (tabId, details) => {
        if (typeof tabId === 'object') { details = tabId; tabId = undefined; }
        return await call('scripting.execute', { tabId, files: details.file ? [details.file] : [], code: details.code, allFrames: !!details.allFrames });
      }),
      insertCSS: api(async (tabId, details) => {
        if (typeof tabId === 'object') { details = tabId; tabId = undefined; }
        await call('scripting.css', { tabId, files: details.file ? [details.file] : [], css: details.code });
      }),
      onUpdated: new WEvent(), onCreated: new WEvent(), onRemoved: new WEvent(), onActivated: new WEvent(),
      onReplaced: noopEvent(), onMoved: noopEvent(), onHighlighted: noopEvent(), onAttached: noopEvent(), onDetached: noopEvent(),
    };
    const windows = {
      WINDOW_ID_CURRENT: -2, WINDOW_ID_NONE: -1,
      getAll: api(async (o) => [{ id: 1, focused: true, type: 'normal', state: 'normal', incognito: false, tabs: (o && o.populate) ? await call('tabs.query', {}) : undefined }]),
      getCurrent: api(async () => ({ id: 1, focused: true, type: 'normal', state: 'normal', incognito: false })),
      getLastFocused: api(async () => ({ id: 1, focused: true, type: 'normal', state: 'normal', incognito: false })),
      get: api(async () => ({ id: 1, focused: true, type: 'normal', state: 'normal', incognito: false })),
      create: api(async (p) => { const t = await call('tabs.create', { url: p && (Array.isArray(p.url) ? p.url[0] : p.url) }); return { id: 1, tabs: [t] }; }),
      update: api(async () => ({ id: 1 })),
      onFocusChanged: noopEvent(), onCreated: noopEvent(), onRemoved: noopEvent(),
    };

    // ---- scripting ------------------------------------------------------------------------------
    const scripting = {
      executeScript: api(async (d) => {
        const target = d.target || {};
        const code = d.func ? '(' + d.func.toString() + ').apply(null, ' + JSON.stringify(d.args || []) + ')' : undefined;
        return await call('scripting.execute', { tabId: target.tabId, files: d.files || [], code, allFrames: !!target.allFrames, world: d.world || 'ISOLATED' });
      }),
      insertCSS: api(async (d) => { await call('scripting.css', { tabId: (d.target || {}).tabId, files: d.files || [], css: d.css }); }),
      removeCSS: api(async () => {}),
      registerContentScripts: api(async () => {}),
      unregisterContentScripts: api(async () => {}),
      updateContentScripts: api(async () => {}),
      getRegisteredContentScripts: api(async () => []),
      ExecutionWorld: { ISOLATED: 'ISOLATED', MAIN: 'MAIN' },
    };

    // ---- alarms ---------------------------------------------------------------------------------
    const alarmTimers = new Map();
    const onAlarm = new WEvent();
    const alarms = {
      create: (...a) => {
        const name = typeof a[0] === 'string' ? a[0] : '';
        const info = (typeof a[0] === 'string' ? a[1] : a[0]) || {};
        alarms.clear(name);
        const delay = info.when ? Math.max(0, info.when - Date.now()) : (info.delayInMinutes || info.periodInMinutes || 0) * 60000;
        const alarm = { name, scheduledTime: Date.now() + delay, periodInMinutes: info.periodInMinutes };
        const fire = () => { onAlarm._fire(alarm); if (info.periodInMinutes) { alarm.scheduledTime = Date.now() + info.periodInMinutes * 60000; alarmTimers.set(name, { alarm, t: setTimeout(fire, info.periodInMinutes * 60000) }); } else alarmTimers.delete(name); };
        alarmTimers.set(name, { alarm, t: setTimeout(fire, delay) });
        return Promise.resolve();
      },
      get: api(async (name) => (alarmTimers.get(name || '') || {}).alarm),
      getAll: api(async () => [...alarmTimers.values()].map((x) => x.alarm)),
      clear: api(async (name) => { const x = alarmTimers.get(name || ''); if (x) { clearTimeout(x.t); alarmTimers.delete(name || ''); return true; } return false; }),
      clearAll: api(async () => { for (const x of alarmTimers.values()) clearTimeout(x.t); alarmTimers.clear(); return true; }),
      onAlarm,
    };

    // ---- the rest -------------------------------------------------------------------------------
    const actionApi = {
      setBadgeText: api(async () => {}), getBadgeText: api(async () => ''), setBadgeBackgroundColor: api(async () => {}),
      setBadgeTextColor: api(async () => {}), setIcon: api(async () => {}), setTitle: api(async () => {}), getTitle: api(async () => ''),
      setPopup: api(async () => {}), getPopup: api(async () => ''), enable: api(async () => {}), disable: api(async () => {}),
      openPopup: api(async () => { await call('action.openPopup', {}); }),
      onClicked: new WEvent(),
    };
    const permissions = {
      contains: api(async () => true), request: api(async () => true), remove: api(async () => true),
      getAll: api(async () => ({ permissions: manifest.permissions || [], origins: manifest.host_permissions || [] })),
      onAdded: noopEvent(), onRemoved: noopEvent(),
    };

    const chromeObj = {
      runtime, storage, tabs, windows, scripting, alarms, permissions,
      action: actionApi, browserAction: actionApi, pageAction: actionApi,
      i18n: {
        getMessage, getUILanguage: () => cfg.uiLang || 'en-US',
        getAcceptLanguages: api(async () => [cfg.uiLang || 'en-US', 'en']),
        detectLanguage: api(async () => ({ isReliable: false, languages: [] })),
      },
      extension: {
        inIncognitoContext: false, getURL: runtime.getURL, isAllowedIncognitoAccess: api(async () => false),
        isAllowedFileSchemeAccess: api(async () => false), getBackgroundPage: () => null, getViews: () => [],
      },
      commands: { getAll: api(async () => []), onCommand: noopEvent() },
      contextMenus: { create: () => 0, update: api(async () => {}), remove: api(async () => {}), removeAll: api(async () => {}), onClicked: noopEvent() },
      webNavigation: { onCommitted: new WEvent(), onCompleted: new WEvent(), onHistoryStateUpdated: new WEvent(), onBeforeNavigate: new WEvent(), onDOMContentLoaded: new WEvent(), getAllFrames: api(async () => []), getFrame: api(async () => null) },
      notifications: { create: api(async () => ''), clear: api(async () => true), onClicked: noopEvent(), onClosed: noopEvent() },
      idle: { queryState: api(async () => 'active'), onStateChanged: noopEvent(), setDetectionInterval: () => {} },
      declarativeNetRequest: { getDynamicRules: api(async () => []), updateDynamicRules: api(async () => {}), getSessionRules: api(async () => []), updateSessionRules: api(async () => {}), getEnabledRulesets: api(async () => []), updateEnabledRulesets: api(async () => {}) },
    };
    if (CTX === 'content') {
      // Content scripts only see a subset, like Chrome.
      for (const k of ['tabs', 'windows', 'scripting', 'alarms', 'action', 'browserAction', 'pageAction', 'commands', 'contextMenus', 'webNavigation', 'notifications', 'idle', 'declarativeNetRequest']) delete chromeObj[k];
      chromeObj.permissions = permissions;
    }
    Object.defineProperty(globalThis, 'chrome', { value: chromeObj, writable: true, configurable: true });

    // ---- extension pages: route cross-origin fetches through the host (extensions aren't bound by CORS) ----
    if (CTX !== 'content') {
      const pageFetch = globalThis.fetch.bind(globalThis);
      const toB64 = (buf) => { let s = ''; const b = new Uint8Array(buf); for (let i = 0; i < b.length; i += 0x8000) s += String.fromCharCode.apply(null, b.subarray(i, i + 0x8000)); return btoa(s); };
      globalThis.fetch = async function (input, init) {
        const req = input instanceof Request ? input : null;
        const url = new URL(req ? req.url : String(input), location.href);
        if (url.protocol !== 'http:' && url.protocol !== 'https:') return pageFetch(input, init);
        init = init || {};
        const signal = init.signal || (req && req.signal);
        if (signal && signal.aborted) throw new DOMException('The operation was aborted.', 'AbortError');
        const headers = {};
        new Headers(init.headers || (req && req.headers) || {}).forEach((v, k) => { headers[k] = v; });
        let body = init.body !== undefined ? init.body : undefined;
        if (body === undefined && req && req.method !== 'GET' && req.method !== 'HEAD') body = await req.arrayBuffer();
        let bodyB64 = null;
        if (body != null) {
          if (typeof body === 'string') bodyB64 = toB64(new TextEncoder().encode(body));
          else if (body instanceof URLSearchParams) { bodyB64 = toB64(new TextEncoder().encode(body.toString())); if (!headers['content-type']) headers['content-type'] = 'application/x-www-form-urlencoded;charset=UTF-8'; }
          else if (body instanceof Blob) bodyB64 = toB64(await body.arrayBuffer());
          else if (body instanceof ArrayBuffer) bodyB64 = toB64(body);
          else if (ArrayBuffer.isView(body)) bodyB64 = toB64(body.buffer.slice(body.byteOffset, body.byteOffset + body.byteLength));
          else if (body instanceof FormData) { const r = new Response(body); headers['content-type'] = r.headers.get('content-type'); bodyB64 = toB64(await r.arrayBuffer()); }
          else bodyB64 = toB64(new TextEncoder().encode(String(body)));
        }
        const p = call('fetch', {
          url: url.href, method: (init.method || (req && req.method) || 'GET').toUpperCase(), headers, body: bodyB64,
          credentials: init.credentials || (req && req.credentials) || 'same-origin', redirect: init.redirect || 'follow',
        });
        const res = await (signal ? Promise.race([p, new Promise((_, rej) => signal.addEventListener('abort', () => rej(new DOMException('The operation was aborted.', 'AbortError')), { once: true }))]) : p);
        if (res.error) throw new TypeError('Load failed: ' + res.error);
        const bin = atob(res.body || '');
        const bytes = new Uint8Array(bin.length);
        for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
        const nullBody = [101, 103, 204, 205, 304].includes(res.status);
        const response = new Response(nullBody ? null : bytes, { status: res.status, statusText: res.statusText || '', headers: res.headers || {} });
        Object.defineProperty(response, 'url', { value: res.url });
        Object.defineProperty(response, 'redirected', { value: !!res.redirected });
        return response;
      };
      if (!globalThis.crypto || !globalThis.crypto.subtle) {
        // Non-secure custom-scheme origins don't get SubtleCrypto; provide digest() through the host.
        const subtle = {
          async digest(alg, data) {
            const name = (typeof alg === 'string' ? alg : alg.name).toUpperCase();
            const buf = data instanceof ArrayBuffer ? data : data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength);
            const out = await call('crypto.digest', { alg: name, data: toB64(buf) });
            const bin = atob(out); const b = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) b[i] = bin.charCodeAt(i);
            return b.buffer;
          },
        };
        try { Object.defineProperty(globalThis.crypto, 'subtle', { value: subtle, configurable: true }); } catch (e) {}
      }
      if (CTX === 'background') {
        // Service-worker globals the background scripts expect.
        globalThis.importScripts = function (...urls) {
          for (const u of urls) {
            const x = new XMLHttpRequest();
            x.open('GET', new URL(u, location.href).href, false); x.send();
            (0, eval)(x.responseText + '\n//# sourceURL=' + u);
          }
        };
        globalThis.registration = globalThis.registration || { scope: BASE, showNotification: async () => {}, getNotifications: async () => [], unregister: async () => true };
        globalThis.clients = globalThis.clients || { matchAll: async () => [], claim: async () => {}, openWindow: async (u) => chrome.tabs.create({ url: u }) };
        globalThis.skipWaiting = globalThis.skipWaiting || (async () => {});
      }
    }

    // ---- inbound from the host ------------------------------------------------------------------
    globalThis.__winext = {
      receive(kind, payloadJSON) {
        const p = JSON.parse(payloadJSON || 'null');
        switch (kind) {
          case 'message':
            return deliverMessage(p.msg, p.sender).then((r) => JSON.stringify(r));
          case 'storageChanged': {
            const area = storage[p.area];
            storageOnChanged._fire(p.changes, p.area);
            if (area) area._ev._fire(p.changes);
            return 'ok';
          }
          case 'portConnect': {
            if (!onConnect.hasListeners()) return JSON.stringify({ accepted: false });
            const port = makePort(p.portId, p.name, p.sender);
            onConnect._fire(port);
            return JSON.stringify({ accepted: true });
          }
          case 'portMessage': {
            const port = ports.get(p.portId);
            if (port) port.onMessage._fire(clone(p.msg), port);
            return 'ok';
          }
          case 'portDisconnect': {
            const port = ports.get(p.portId);
            if (port && !port._closed) { port._closed = true; ports.delete(p.portId); port.onDisconnect._fire(port); }
            return 'ok';
          }
          case 'event': {
            // e.g. {path: 'runtime.onInstalled', args: [{reason: 'install'}]}
            let o = chromeObj;
            for (const seg of p.path.split('.')) o = o && o[seg];
            if (o && o._fire) o._fire(...(p.args || []));
            return 'ok';
          }
          case 'eval':
            return String((0, eval)(p.code));
        }
        return 'unknown';
      },
    };
    if (CTX === 'content') fireAndForget('frame.hello', { url: location.href });
  };
})();
