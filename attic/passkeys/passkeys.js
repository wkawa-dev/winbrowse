// WinBrowse passkeys: navigator.credentials (WebAuthn) backed by the app's own passkey store.
// Sideloaded apps can't use iCloud Keychain passkeys from a web view, so WinBrowse is the authenticator itself:
// keys live in the iOS keychain, every use is confirmed with Face ID / passcode, and the native side builds and
// signs clientDataJSON with the frame's real origin.
(function () {
  if (window.__winPasskeys || !window.isSecureContext || !navigator.credentials) return;
  window.__winPasskeys = true;
  const post = (body) => window.webkit.messageHandlers.winpasskey.postMessage(body);

  const b64u = (buf) => {
    const b = buf instanceof ArrayBuffer ? new Uint8Array(buf) : ArrayBuffer.isView(buf) ? new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength) : new Uint8Array(0);
    let s = ''; for (let i = 0; i < b.length; i++) s += String.fromCharCode(b[i]);
    return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  };
  const unb64u = (s) => {
    s = String(s || '').replace(/-/g, '+').replace(/_/g, '/'); while (s.length % 4) s += '=';
    const bin = atob(s), out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out.buffer;
  };
  const fail = (name, msg) => new DOMException(msg || name, name);
  const list = (a) => (Array.isArray(a) ? a : []).map((c) => ({ id: b64u(c.id), type: c.type || 'public-key' }));

  const proto = (ctor) => (typeof ctor === 'function' && ctor.prototype) || Object.prototype;
  const define = (obj, props) => { for (const k in props) Object.defineProperty(obj, k, { value: props[k], enumerable: true, configurable: true }); return obj; };

  function makeCredential(r, kind) {
    const rawId = unb64u(r.id);
    const response = Object.create(proto(kind === 'create' ? window.AuthenticatorAttestationResponse : window.AuthenticatorAssertionResponse));
    const clientDataJSON = unb64u(r.clientDataJSON);
    const authenticatorData = unb64u(r.authenticatorData);
    if (kind === 'create') {
      const attestationObject = unb64u(r.attestationObject), publicKey = unb64u(r.publicKey);
      define(response, {
        clientDataJSON, attestationObject,
        getTransports: () => ['internal', 'hybrid'],
        getAuthenticatorData: () => authenticatorData,
        getPublicKey: () => publicKey,
        getPublicKeyAlgorithm: () => -7,
        toJSON: () => ({ clientDataJSON: r.clientDataJSON, attestationObject: r.attestationObject, authenticatorData: r.authenticatorData,
          transports: ['internal', 'hybrid'], publicKey: r.publicKey, publicKeyAlgorithm: -7 }),
      });
    } else {
      define(response, {
        clientDataJSON, authenticatorData,
        signature: unb64u(r.signature),
        userHandle: r.userHandle ? unb64u(r.userHandle) : null,
        toJSON: () => ({ clientDataJSON: r.clientDataJSON, authenticatorData: r.authenticatorData, signature: r.signature, userHandle: r.userHandle || undefined }),
      });
    }
    const ext = r.extensions || {};
    const cred = Object.create(proto(window.PublicKeyCredential));
    return define(cred, {
      id: r.id, rawId, type: 'public-key', response, authenticatorAttachment: 'platform',
      getClientExtensionResults: () => ext,
      toJSON: () => ({ id: r.id, rawId: r.id, type: 'public-key', authenticatorAttachment: 'platform', response: response.toJSON(), clientExtensionResults: ext }),
    });
  }

  let seq = 0;
  function run(kind, body, signal) {
    if (signal && signal.aborted) return Promise.reject(signal.reason || fail('AbortError', 'The operation was aborted.'));
    const req = ++seq;
    return new Promise((resolve, reject) => {
      let done = false;
      const onAbort = () => { if (done) return; done = true; post({ op: 'cancel', req }).catch(() => {}); reject(signal.reason || fail('AbortError', 'The operation was aborted.')); };
      if (signal) signal.addEventListener('abort', onAbort, { once: true });
      post(Object.assign({ op: kind, req }, body)).then((r) => {
        if (done) return; done = true;
        if (signal) signal.removeEventListener('abort', onAbort);
        if (r && r.error) return reject(fail(r.error, r.message));
        if (r && r.pending) return; // conditional mediation with nothing to offer: stays pending, like Safari
        resolve(makeCredential(r, kind));
      }, (e) => { if (done) return; done = true; reject(fail('NotAllowedError', String(e && e.message || e))); });
    });
  }

  const C = Object.getPrototypeOf(navigator.credentials);
  const nativeCreate = C.create, nativeGet = C.get;

  C.create = function (opts) {
    const pk = opts && opts.publicKey;
    if (!pk) return nativeCreate.apply(this, arguments);
    try {
      return run('create', {
        rp: { id: pk.rp && pk.rp.id, name: pk.rp && pk.rp.name },
        user: { id: b64u(pk.user.id), name: pk.user.name, displayName: pk.user.displayName },
        challenge: b64u(pk.challenge),
        algs: (pk.pubKeyCredParams || []).map((p) => p.alg),
        exclude: list(pk.excludeCredentials),
        attachment: pk.authenticatorSelection && pk.authenticatorSelection.authenticatorAttachment,
        extensions: pk.extensions && pk.extensions.credProps ? { credProps: true } : {},
      }, opts.signal);
    } catch (e) { return Promise.reject(fail('TypeError' === e.name ? 'NotSupportedError' : 'NotAllowedError', String(e.message || e))); }
  };

  C.get = function (opts) {
    const pk = opts && opts.publicKey;
    if (!pk) return nativeGet.apply(this, arguments);
    try {
      return run('get', {
        rpId: pk.rpId, challenge: b64u(pk.challenge), allow: list(pk.allowCredentials),
        conditional: opts.mediation === 'conditional',
      }, opts.signal);
    } catch (e) { return Promise.reject(fail('NotAllowedError', String(e.message || e))); }
  };

  const PKC = window.PublicKeyCredential;
  if (PKC) {
    const val = (k, v) => { try { Object.defineProperty(PKC, k, { value: v, configurable: true, writable: true }); } catch (e) {} };
    val('isUserVerifyingPlatformAuthenticatorAvailable', () => Promise.resolve(true));
    val('isConditionalMediationAvailable', () => Promise.resolve(true));
    val('getClientCapabilities', () => Promise.resolve({ conditionalCreate: false, conditionalGet: true, hybridTransport: false,
      passkeyPlatformAuthenticator: true, userVerifyingPlatformAuthenticator: true, relatedOrigins: false, signalAllAcceptedCredentials: false,
      signalCurrentUserDetails: false, signalUnknownCredential: false }));
    if (!PKC.parseCreationOptionsFromJSON) val('parseCreationOptionsFromJSON', (j) => Object.assign({}, j, {
      challenge: unb64u(j.challenge), user: Object.assign({}, j.user, { id: unb64u(j.user.id) }),
      excludeCredentials: (j.excludeCredentials || []).map((c) => Object.assign({}, c, { id: unb64u(c.id) })) }));
    if (!PKC.parseRequestOptionsFromJSON) val('parseRequestOptionsFromJSON', (j) => Object.assign({}, j, {
      challenge: unb64u(j.challenge), allowCredentials: (j.allowCredentials || []).map((c) => Object.assign({}, c, { id: unb64u(c.id) })) }));
  }
})();
