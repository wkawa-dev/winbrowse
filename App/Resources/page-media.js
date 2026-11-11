(function (kit) {
  'use strict';
  const { apply } = kit;
  let playedSound = false;
  const audible = (m) => m instanceof HTMLMediaElement && !m.paused && !m.muted && m.volume > 0;
  const notice = (e) => { if (!playedSound && audible(e.target)) playedSound = true; };
  document.addEventListener('play', notice, true);
  document.addEventListener('volumechange', notice, true);

  const whilePlaying = (value) => (original) => function () {
    const real = apply(original, this, []);
    return playedSound && this === document ? value : real;
  };
  kit.replaceGetter(Document.prototype, 'hidden', whilePlaying(false));
  kit.replaceGetter(Document.prototype, 'webkitHidden', whilePlaying(false));
  kit.replaceGetter(Document.prototype, 'visibilityState', whilePlaying('visible'));
  kit.replaceGetter(Document.prototype, 'webkitVisibilityState', whilePlaying('visible'));
  kit.replaceMethod(Document.prototype, 'hasFocus', whilePlaying(true));

  const stop = (e) => { if (playedSound) e.stopImmediatePropagation(); };
  for (const t of ['visibilitychange', 'webkitvisibilitychange']) {
    window.addEventListener(t, stop, true);
    document.addEventListener(t, stop, true);
  }

  kit.replaceMethod(window.MediaSession && MediaSession.prototype, 'setActionHandler', (original) => function (action, handler) {
    if (action !== 'pause' || typeof handler !== 'function') return apply(original, this, arguments);
    return apply(original, this, [action, function (details) { kit.signal('userpause'); return apply(handler, this, [details]); }]);
  });
})
