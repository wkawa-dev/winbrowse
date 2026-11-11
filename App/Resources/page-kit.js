(function (channel) {
  'use strict';
  const { create, defineProperty, getOwnPropertyDescriptor } = Object;
  const { apply } = Reflect;
  const P = Promise;
  const stringify = JSON.stringify;
  const parse = JSON.parse;
  const CE = CustomEvent;
  const dispatch = EventTarget.prototype.dispatchEvent;
  const listen = EventTarget.prototype.addEventListener;
  const nativeToString = Function.prototype.toString;
  const nativeTemplate = apply(nativeToString, Object.prototype.hasOwnProperty, []);
  const disguised = new WeakMap();

  const nativeSource = (name) => nativeTemplate.replace('hasOwnProperty', name);

  const source = function () {
    const d = disguised.get(this);
    if (typeof d === 'string') return d;
    return apply(nativeToString, d === undefined ? this : d, []);
  };
  const toString = { toString() { return apply(source, this, []); } }.toString;
  defineProperty(Function.prototype, 'toString', { ...getOwnPropertyDescriptor(Function.prototype, 'toString'), value: toString });
  disguised.set(toString, nativeToString);

  const method = (name, length, impl) => {
    const fn = { [name](...args) { return apply(impl, this, args); } }[name];
    defineProperty(fn, 'length', { value: length });
    return fn;
  };

  const replaceMethod = (target, name, wrap) => {
    const desc = target && getOwnPropertyDescriptor(target, name);
    if (!desc || typeof desc.value !== 'function') return false;
    const original = desc.value;
    const fn = method(name, original.length, wrap(original));
    disguised.set(fn, original);
    defineProperty(target, name, { ...desc, value: fn });
    return true;
  };

  const addMethod = (target, name, length, impl) => {
    if (!target || getOwnPropertyDescriptor(target, name)) return false;
    const fn = method(name, length, impl);
    disguised.set(fn, nativeSource(name));
    defineProperty(target, name, { value: fn, writable: true, enumerable: false, configurable: true });
    return true;
  };

  const replaceGetter = (target, name, wrap) => {
    const desc = target && getOwnPropertyDescriptor(target, name);
    if (!desc || typeof desc.get !== 'function') return false;
    const original = desc.get;
    const impl = wrap(original);
    const get = getOwnPropertyDescriptor({ get [name]() { return apply(impl, this, []); } }, name).get;
    disguised.set(get, original);
    defineProperty(target, name, { ...desc, get });
    return true;
  };

  const waiting = create(null);
  let seq = 0;
  apply(listen, document, [channel + ':res', (e) => {
    const m = parse(e.detail);
    const w = waiting[m.id];
    if (!w) return;
    delete waiting[m.id];
    if (m.ok) w.resolve(m.value); else w.reject(m.error);
  }]);

  const call = (to, body) => new P((resolve, reject) => {
    const id = ++seq;
    waiting[id] = { resolve, reject };
    apply(dispatch, document, [new CE(channel + ':req', { detail: stringify({ id, to, body }) })]);
  });

  const signal = (name) => { apply(dispatch, document, [new CE(channel + ':' + name)]); };

  return { apply, replaceMethod, addMethod, replaceGetter, call, signal };
})
