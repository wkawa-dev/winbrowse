(function (kit) {
  'use strict';
  if (window.top !== window || !/(^|\.)(x|twitter)\.com$/.test(location.hostname)) return;
  const { apply } = kit;

  const isTimeline = (u) => typeof u === 'string' && u.includes('/graphql/') &&
    /Timeline|Tweets|HomeLatest|SearchTimeline|UserMedia|Likes|Bookmarks|ListLatest|TweetDetail|ModeratedTimeline/i.test(u);

  const promotedEntry = (e) => {
    if (!e || typeof e !== 'object') return false;
    const id = String(e.entryId || '');
    if (/^(promoted|promotedTweet|promoted-tweet|who-to-follow|who-to-subscribe|pinned-tweets-promo|superhero|premium-upsell|creators-to-follow|messageprompt)/i.test(id)) return true;
    const c = e.content || e.item || {};
    const ic = c.itemContent || (c.item && c.item.itemContent) || {};
    return Boolean(ic.promotedMetadata || c.promotedMetadata);
  };

  const clean = (node, depth) => {
    if (!node || typeof node !== 'object' || depth > 30) return;
    if (Array.isArray(node)) { for (const x of node) clean(x, depth + 1); return; }
    if (Array.isArray(node.entries)) node.entries = node.entries.filter((e) => !promotedEntry(e));
    if (Array.isArray(node.items)) node.items = node.items.filter((e) => !promotedEntry(e) && !(e.item && e.item.itemContent && e.item.itemContent.promotedMetadata));
    if (node.entry && promotedEntry(node.entry)) node.entry = null;
    for (const k in node) { const v = node[k]; if (v && typeof v === 'object') clean(v, depth + 1); }
  };

  const filterText = (text) => {
    try { const j = JSON.parse(text); clean(j, 0); return JSON.stringify(j); } catch (e) { return text; }
  };

  const urls = new WeakMap();
  const cached = new WeakMap();
  const timeline = (xhr) => xhr.readyState === 4 && isTimeline(urls.get(xhr));
  const filtered = (xhr, raw) => {
    let c = cached.get(xhr);
    if (!c || c.raw !== raw) { c = { raw, out: typeof raw === 'string' ? filterText(raw) : raw }; cached.set(xhr, c); }
    return c.out;
  };

  kit.replaceMethod(XMLHttpRequest.prototype, 'open', (original) => function (method, url) {
    urls.set(this, String(url));
    return apply(original, this, arguments);
  });
  kit.replaceGetter(XMLHttpRequest.prototype, 'responseText', (original) => function () {
    const raw = apply(original, this, []);
    return timeline(this) ? filtered(this, raw) : raw;
  });
  kit.replaceGetter(XMLHttpRequest.prototype, 'response', (original) => function () {
    const raw = apply(original, this, []);
    if (!timeline(this)) return raw;
    if (typeof raw === 'string') return filtered(this, raw);
    if (raw && typeof raw === 'object' && !(raw instanceof ArrayBuffer) && !(raw instanceof Blob)) clean(raw, 0);
    return raw;
  });

  kit.replaceMethod(window, 'fetch', (original) => function (input) {
    const pending = apply(original, this, arguments);
    const url = typeof input === 'string' ? input : input instanceof URL ? input.href : (input && input.url) || '';
    if (!isTimeline(url)) return pending;
    return pending.then((res) => res.clone().text().then((text) => {
      const out = new Response(filterText(text), { status: res.status, statusText: res.statusText, headers: res.headers });
      return Object.defineProperties(out, { url: { value: res.url }, redirected: { value: res.redirected }, type: { value: res.type } });
    }, () => res));
  });
})
