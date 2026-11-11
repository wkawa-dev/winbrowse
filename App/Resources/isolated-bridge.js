(function (channel) {
  'use strict';
  const handlers = window.webkit && window.webkit.messageHandlers;
  document.addEventListener(channel + ':req', (e) => {
    let m;
    try { m = JSON.parse(e.detail); } catch (err) { return; }
    const respond = (r) => document.dispatchEvent(new CustomEvent(channel + ':res', { detail: JSON.stringify({ id: m.id, ...r }) }));
    const handler = handlers && handlers[m.to];
    if (!handler) { respond({ ok: false, error: 'no handler named ' + m.to }); return; }
    Promise.resolve()
      .then(() => handler.postMessage(m.body))
      .then((value) => respond({ ok: true, value: value === undefined ? null : value }),
        (err) => respond({ ok: false, error: String((err && err.message) || err) }));
  });
})
