(function (channel) {
  'use strict';
  const post = (m) => { try { window.webkit.messageHandlers.winmedia.postMessage(m); } catch (e) {} };
  const isMedia = (t) => t instanceof HTMLMediaElement;
  const wasPlaying = new WeakSet();
  let lastInput = 0;
  const input = () => { lastInput = Date.now(); };

  document.addEventListener('play', (e) => { if (isMedia(e.target)) post({ state: 'playing' }); }, true);
  document.addEventListener('pause', (e) => { if (isMedia(e.target)) post({ state: 'paused', user: Date.now() - lastInput < 1500 }); }, true);
  for (const t of ['touchend', 'mouseup', 'keydown', 'click', channel + ':userpause']) document.addEventListener(t, input, true);

  const elements = () => document.querySelectorAll('video, audio');
  window.winbrowseMedia = {
    mark() {
      for (const m of elements()) { if (!m.paused && !m.ended) wasPlaying.add(m); else wasPlaying.delete(m); }
    },
    resume() {
      let n = 0;
      for (const m of elements()) { if (m.paused && !m.ended && wasPlaying.has(m)) { m.play().catch(() => {}); n++; } }
      return n;
    },
  };
})
