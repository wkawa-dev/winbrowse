(function (kit) {
  'use strict';
  if (!window.isSecureContext || !window.CredentialsContainer) return;
  const { apply } = kit;
  const P = Promise;
  const later = setTimeout.bind(window);
  const cancelLater = clearTimeout.bind(window);

  const b64u = (buf) => {
    const b = buf instanceof ArrayBuffer ? new Uint8Array(buf) : ArrayBuffer.isView(buf) ? new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength) : new Uint8Array(0);
    let s = '';
    for (let i = 0; i < b.length; i++) s += String.fromCharCode(b[i]);
    return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  };
  const unb64u = (s) => {
    s = String(s || '').replace(/-/g, '+').replace(/_/g, '/');
    while (s.length % 4) s += '=';
    const bin = atob(s), out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out.buffer;
  };
  const fail = (name, msg) => new DOMException(msg || name, name);
  const notAllowed = () => fail('NotAllowedError', 'The operation either timed out or was not allowed.');
  const list = (a) => (Array.isArray(a) ? a : []).map((c) => ({ id: b64u(c.id), type: c.type || 'public-key' }));
  const proto = (ctor) => (typeof ctor === 'function' && ctor.prototype) || Object.prototype;
  const define = (obj, props) => {
    for (const k in props) Object.defineProperty(obj, k, { value: props[k], enumerable: true, configurable: true });
    return obj;
  };

  function makeCredential(r, kind) {
    const response = Object.create(proto(kind === 'create' ? window.AuthenticatorAttestationResponse : window.AuthenticatorAssertionResponse));
    const clientDataJSON = unb64u(r.clientDataJSON);
    const authenticatorData = unb64u(r.authenticatorData);
    if (kind === 'create') {
      const attestationObject = unb64u(r.attestationObject), publicKey = unb64u(r.publicKey);
      define(response, {
        clientDataJSON, attestationObject,
        getTransports: () => ['internal'],
        getAuthenticatorData: () => authenticatorData,
        getPublicKey: () => publicKey,
        getPublicKeyAlgorithm: () => -7,
        toJSON: () => ({ clientDataJSON: r.clientDataJSON, attestationObject: r.attestationObject, authenticatorData: r.authenticatorData,
          transports: ['internal'], publicKey: r.publicKey, publicKeyAlgorithm: -7 }),
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
    return define(Object.create(proto(window.PublicKeyCredential)), {
      id: r.id, rawId: unb64u(r.id), type: 'public-key', response, authenticatorAttachment: 'platform',
      getClientExtensionResults: () => ext,
      toJSON: () => ({ id: r.id, rawId: r.id, type: 'public-key', authenticatorAttachment: 'platform', response: response.toJSON(), clientExtensionResults: ext }),
    });
  }

  let seq = Math.floor(Math.random() * 2 ** 52);
  function run(kind, body, signal, timeout) {
    if (signal && signal.aborted) return P.reject(signal.reason || fail('AbortError', 'The operation was aborted.'));
    const req = ++seq;
    return new P((resolve, reject) => {
      let settled = false;
      let timer = 0;
      const settle = () => {
        settled = true;
        cancelLater(timer);
        if (signal) signal.removeEventListener('abort', onAbort);
      };
      const cancel = (error) => {
        if (settled) return;
        settle();
        kit.call('winpasskey', { op: 'cancel', req }).catch(() => {});
        reject(error);
      };
      const onAbort = () => cancel(signal.reason || fail('AbortError', 'The operation was aborted.'));
      if (signal) signal.addEventListener('abort', onAbort, { once: true });
      if (!body.conditional && timeout > 0) timer = later(() => cancel(notAllowed()), timeout);
      kit.call('winpasskey', { op: kind, req, ...body }).then((r) => {
        if (settled || (r && r.pending)) return;
        settle();
        if (r && r.error) reject(fail(r.error, r.message)); else resolve(makeCredential(r, kind));
      }, (e) => {
        if (settled) return;
        settle();
        reject(fail('NotAllowedError', String(e)));
      });
    });
  }

  kit.replaceMethod(CredentialsContainer.prototype, 'create', (original) => function (options) {
    const pk = options && options.publicKey;
    if (!pk) return apply(original, this, arguments);
    try {
      return run('create', {
        rp: { id: pk.rp && pk.rp.id, name: pk.rp && pk.rp.name },
        user: { id: b64u(pk.user.id), name: pk.user.name, displayName: pk.user.displayName },
        challenge: b64u(pk.challenge),
        algs: (pk.pubKeyCredParams || []).map((p) => p.alg),
        exclude: list(pk.excludeCredentials),
        attachment: pk.authenticatorSelection && pk.authenticatorSelection.authenticatorAttachment,
        extensions: pk.extensions && pk.extensions.credProps ? { credProps: true } : {},
      }, options.signal, pk.timeout);
    } catch (e) { return P.reject(fail(e.name === 'TypeError' ? 'NotSupportedError' : 'NotAllowedError', String(e.message || e))); }
  });

  kit.replaceMethod(CredentialsContainer.prototype, 'get', (original) => function (options) {
    const pk = options && options.publicKey;
    if (!pk) return apply(original, this, arguments);
    try {
      return run('get', {
        rpId: pk.rpId, challenge: b64u(pk.challenge), allow: list(pk.allowCredentials),
        conditional: options.mediation === 'conditional',
      }, options.signal, pk.timeout);
    } catch (e) { return P.reject(fail('NotAllowedError', String(e.message || e))); }
  });

  const PKC = window.PublicKeyCredential;
  if (!PKC) return;
  const capabilities = { conditionalCreate: false, conditionalGet: true, hybridTransport: false,
    passkeyPlatformAuthenticator: true, userVerifyingPlatformAuthenticator: true, relatedOrigins: false,
    signalAllAcceptedCredentials: false, signalCurrentUserDetails: false, signalUnknownCredential: false };
  const answer = (value) => () => function () { return P.resolve(typeof value === 'function' ? value() : value); };
  const always = (name, length, value) => {
    if (!kit.replaceMethod(PKC, name, answer(value))) kit.addMethod(PKC, name, length, answer(value)());
  };
  always('isUserVerifyingPlatformAuthenticatorAvailable', 0, true);
  always('isConditionalMediationAvailable', 0, true);
  always('getClientCapabilities', 0, () => ({ ...capabilities }));
  kit.addMethod(PKC, 'parseCreationOptionsFromJSON', 1, (j) => ({ ...j,
    challenge: unb64u(j.challenge), user: { ...j.user, id: unb64u(j.user.id) },
    excludeCredentials: (j.excludeCredentials || []).map((c) => ({ ...c, id: unb64u(c.id) })) }));
  kit.addMethod(PKC, 'parseRequestOptionsFromJSON', 1, (j) => ({ ...j,
    challenge: unb64u(j.challenge), allowCredentials: (j.allowCredentials || []).map((c) => ({ ...c, id: unb64u(c.id) })) }));
})
