(function attachStyle(text) {
  'use strict';
  const style = document.createElement('style');
  style.textContent = text;
  const attach = () => {
    if (style.isConnected) return true;
    const parent = document.head || document.documentElement;
    if (!parent) return false;
    parent.appendChild(style);
    return true;
  };
  if (!attach()) new MutationObserver((m, o) => { if (attach()) o.disconnect(); }).observe(document, { childList: true, subtree: true });
  return { set(css) { style.textContent = css; attach(); } };
})
