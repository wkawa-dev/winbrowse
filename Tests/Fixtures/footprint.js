const paths = [
  'CredentialsContainer.prototype.create', 'CredentialsContainer.prototype.get', 'CredentialsContainer.prototype.store',
  'PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable', 'PublicKeyCredential.isConditionalMediationAvailable',
  'PublicKeyCredential.getClientCapabilities', 'PublicKeyCredential.parseCreationOptionsFromJSON', 'PublicKeyCredential.parseRequestOptionsFromJSON',
  'Document.prototype.hidden', 'Document.prototype.webkitHidden', 'Document.prototype.visibilityState', 'Document.prototype.webkitVisibilityState',
  'Document.prototype.hasFocus', 'Document.prototype.getElementById', 'MediaSession.prototype.setActionHandler',
  'XMLHttpRequest.prototype.open', 'XMLHttpRequest.prototype.send', 'XMLHttpRequest.prototype.responseText', 'XMLHttpRequest.prototype.response',
  'window.fetch', 'window.setTimeout', 'Function.prototype.toString', 'Function.prototype.call', 'Function.prototype.apply',
  'EventTarget.prototype.addEventListener', 'EventTarget.prototype.dispatchEvent', 'History.prototype.pushState',
  'Element.prototype.attachShadow', 'Node.prototype.appendChild', 'Object.defineProperty', 'JSON.parse',
];

const attempt = (f) => { try { return f(); } catch (e) { return 'throws ' + e.constructor.name; } };

const describe = (fn) => {
  if (fn === undefined) return null;
  if (typeof fn !== 'function') return typeof fn;
  return {
    name: fn.name,
    length: fn.length,
    source: attempt(() => Function.prototype.toString.call(fn)),
    sourceViaMethod: attempt(() => fn.toString()),
    ownKeys: Reflect.ownKeys(fn).map(String).sort(),
    constructor: attempt(() => { Reflect.construct(String, [], fn); return true; }),
  };
};

const resolve = (path) => {
  const parts = path.split('.');
  const key = parts.pop();
  let target = window;
  for (const p of parts) {
    if (p === 'window') continue;
    target = target == null ? undefined : target[p];
  }
  return { target, key };
};

const property = (path) => {
  const { target, key } = resolve(path);
  const d = target == null ? undefined : Object.getOwnPropertyDescriptor(target, key);
  if (!d) return null;
  return {
    configurable: d.configurable,
    enumerable: d.enumerable,
    writable: 'writable' in d ? d.writable : null,
    value: describe(d.value),
    get: describe(d.get),
    set: describe(d.set),
    getterOnPlainObject: d.get ? attempt(() => { d.get.call({}); return 'returns'; }) : null,
  };
};

const handlers = window.webkit && window.webkit.messageHandlers;
return JSON.stringify({
  properties: Object.fromEntries(paths.map((p) => [p, property(p)])),
  windowNames: Object.getOwnPropertyNames(window).sort(),
  windowSymbols: Object.getOwnPropertySymbols(window).map(String),
  functionPrototypeKeys: Reflect.ownKeys(Function.prototype).map(String).sort(),
  documentPrototypeKeys: Reflect.ownKeys(Document.prototype).map(String).sort(),
  messageHandlers: ['winext', 'winpasskey', 'winmedia', 'winlog', 'ubo'].filter((n) => handlers && handlers[n]),
  webkitObject: typeof window.webkit,
  head: document.head ? document.head.innerHTML : null,
  attributes: [...document.querySelectorAll('*')].flatMap((e) => [...e.attributes].map((a) => a.name)).filter((n) => n.startsWith('data-')).sort(),
});
