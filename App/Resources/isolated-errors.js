(function () {
  'use strict';
  let sent = 0;
  const post = (m) => {
    if (sent >= 50) return;
    sent++;
    try { window.webkit.messageHandlers.winerror.postMessage({ ...m, page: location.href }); } catch (e) {}
  };
  const text = (v) => {
    try {
      if (!v || typeof v !== 'object') return String(v);
      const head = v.message !== undefined ? (v.name ? v.name + ': ' : '') + v.message : String(v);
      return v.stack ? head + '\n' + v.stack : head;
    } catch (e) { return 'unreadable value'; }
  };

  window.addEventListener('error', (e) => {
    const t = e.target;
    if (t && t !== window && t.tagName) {
      post({ kind: 'resource', message: t.tagName.toLowerCase() + ' failed to load', source: t.currentSrc || t.src || t.href || '' });
      return;
    }
    post({ kind: 'error', message: String(e.message), source: e.filename || '', line: e.lineno || 0, column: e.colno || 0, stack: e.error ? text(e.error) : '' });
  }, true);
  window.addEventListener('unhandledrejection', (e) => post({ kind: 'rejection', message: text(e.reason) }));
  document.addEventListener('securitypolicyviolation', (e) => post({
    kind: 'csp', message: e.violatedDirective + ' blocked ' + (e.blockedURI || 'inline code'), source: e.sourceFile || '', line: e.lineNumber || 0,
  }));
})
