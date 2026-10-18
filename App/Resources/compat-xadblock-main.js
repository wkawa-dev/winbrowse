// WinBrowse compat for "The Ad Blocker for X": strip promoted posts and follow suggestions from X's timeline API
// responses before the app renders them, so the feed stays clean even when X changes its markup.
(function () {
  if (window.__winXFeed) return; window.__winXFeed = true;
  const isTimeline = (u) => typeof u === 'string' && u.includes('/graphql/') &&
    /Timeline|Tweets|HomeLatest|SearchTimeline|UserMedia|Likes|Bookmarks|ListLatest|TweetDetail|ModeratedTimeline/i.test(u);

  const promotedEntry = (e) => {
    if (!e || typeof e !== 'object') return false;
    const id = String(e.entryId || '');
    if (/^(promoted|promotedTweet|promoted-tweet|who-to-follow|who-to-subscribe|pinned-tweets-promo|superhero|premium-upsell|creators-to-follow|messageprompt)/i.test(id)) return true;
    const c = e.content || e.item || {};
    const ic = c.itemContent || (c.item && c.item.itemContent) || {};
    if (ic.promotedMetadata || c.promotedMetadata) return true;
    return false;
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

  // XHR (X's API client)
  const XHR = XMLHttpRequest.prototype;
  const open = XHR.open;
  XHR.open = function (m, u) { this.__winXUrl = String(u); return open.apply(this, arguments); };
  const desc = (k) => Object.getOwnPropertyDescriptor(XHR, k);
  const rt = desc('responseText'), r = desc('response');
  const cached = new WeakMap();
  const filtered = (xhr, raw) => {
    if (xhr.readyState !== 4 || !isTimeline(xhr.__winXUrl)) return raw;
    let c = cached.get(xhr);
    if (!c || c.raw !== raw) { c = { raw, out: typeof raw === 'string' ? filterText(raw) : raw }; cached.set(xhr, c); }
    return c.out;
  };
  Object.defineProperty(XHR, 'responseText', { configurable: true, get() { return filtered(this, rt.get.call(this)); } });
  Object.defineProperty(XHR, 'response', {
    configurable: true,
    get() {
      const raw = r.get.call(this);
      if (this.readyState !== 4 || !isTimeline(this.__winXUrl)) return raw;
      if (typeof raw === 'string') return filtered(this, raw);
      if (raw && typeof raw === 'object' && !(raw instanceof ArrayBuffer) && !(raw instanceof Blob)) { clean(raw, 0); }
      return raw;
    },
  });

  // fetch
  const f = window.fetch;
  window.fetch = async function (input, init) {
    const res = await f.apply(this, arguments);
    const url = typeof input === 'string' ? input : (input && input.url) || '';
    if (!isTimeline(url)) return res;
    try {
      const text = await res.clone().text();
      return new Response(filterText(text), { status: res.status, statusText: res.statusText, headers: res.headers });
    } catch (e) { return res; }
  };
})();
