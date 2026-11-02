// ページ（と中の iframe）から動画の URL を探す
(() => {
  if (window.__vsaverLoaded) return;
  window.__vsaverLoaded = true;

  const isTop = window === window.top;
  const MEDIA_RE = /\.(m3u8|mp4|m4v|mov|webm|mkv|3gp|m4a|mp3)(?:$|[?#])/i;
  const TEXT_URL_RE = /(?:https?:)?\/\/[^\s"'<>()\\]+?\.(?:m3u8|mp4|m4v|mov|webm)(?:\?[^\s"'<>()\\]*)?/gi;
  // 細切れの動画パーツ（セグメント）や広告計測っぽいものは除外
  const SKIP_RE = /\.(ts|m4s|aac|vtt|srt)(?:$|[?#])|[?&](range|bytestart|byterange)=|\/(segment|seg|frag|chunk)[-_]?\d+|doubleclick|googlesyndication|\/ads?\//i;

  const found = new Map(); // url -> {url, kind, page, from}
  const childItems = new Map(); // iframe から届いたもの

  try { performance.setResourceTimingBufferSize(20000); } catch (e) {}

  function kindOf(url) {
    const m = url.match(MEDIA_RE);
    if (!m) return null;
    const ext = m[1].toLowerCase();
    if (ext === "m3u8") return "hls";
    if (ext === "m4a" || ext === "mp3") return "audio";
    return "file";
  }

  function add(raw, from) {
    if (!raw || typeof raw !== "string") return;
    let url = raw.trim().replace(/\\u002F/gi, "/").replace(/\\\//g, "/").replace(/&amp;/g, "&");
    if (url.startsWith("blob:") || url.startsWith("data:")) return;
    try { url = new URL(url, location.href).href; } catch (e) { return; }
    if (!/^https?:/.test(url) || SKIP_RE.test(url)) return;
    const kind = kindOf(url) || (from === "video" ? "file" : null);
    if (!kind || found.has(url)) return;
    found.set(url, { url, kind, page: location.href, from });
  }

  function scan() {
    document.querySelectorAll("video, audio, video source, audio source").forEach((el) => {
      add(el.currentSrc || el.src, "video");
      add(el.getAttribute("src"), "video");
    });
    document.querySelectorAll('meta[property^="og:video"], meta[name^="twitter:player:stream"]').forEach((m) => {
      add(m.getAttribute("content"), "meta");
    });
    try {
      performance.getEntriesByType("resource").forEach((e) => add(e.name, "network"));
    } catch (e) {}
    try {
      const html = document.documentElement ? document.documentElement.innerHTML : "";
      const text = html.length > 4e6 ? html.slice(0, 4e6) : html;
      const matches = text.replace(/\\u002F/gi, "/").replace(/\\\//g, "/").match(TEXT_URL_RE) || [];
      matches.forEach((u) => add(u.startsWith("//") ? location.protocol + u : u, "html"));
    } catch (e) {}
  }

  // 同じ形で番号だけ違う URL がたくさんあれば、それは動画の細切れパーツ
  function dropSegments(list) {
    const groups = new Map();
    for (const it of list) {
      if (it.kind === "hls") continue;
      const key = it.url.replace(/[?#].*$/, "").replace(/\d+/g, "#");
      groups.set(key, (groups.get(key) || 0) + 1);
    }
    return list.filter((it) => it.kind === "hls" || groups.get(it.url.replace(/[?#].*$/, "").replace(/\d+/g, "#")) < 3);
  }

  function collect() {
    scan();
    const all = new Map(found);
    for (const items of childItems.values()) for (const it of items) if (!all.has(it.url)) all.set(it.url, it);
    const order = { hls: 0, file: 1, audio: 2 };
    return dropSegments([...all.values()]).sort((a, b) => order[a.kind] - order[b.kind]);
  }

  // ---- iframe → 一番上のページへ報告
  let reportTimer = null;
  function report() {
    clearTimeout(reportTimer);
    reportTimer = setTimeout(() => {
      if (isTop) {
        const n = collect().length;
        try { browser.runtime.sendMessage({ type: "vsaver-count", count: n }).catch(() => {}); } catch (e) {}
      } else {
        scan();
        const items = dropSegments([...found.values()]);
        if (items.length) {
          try { window.top.postMessage({ __vsaver: true, items }, "*"); } catch (e) {}
        }
      }
    }, 800);
  }

  if (isTop) {
    window.addEventListener("message", (ev) => {
      const d = ev.data;
      if (!d || d.__vsaver !== true || !Array.isArray(d.items)) return;
      const clean = d.items.filter((it) => it && typeof it.url === "string" && /^https?:/.test(it.url) && !SKIP_RE.test(it.url))
        .map((it) => ({ url: it.url, kind: it.kind === "hls" || it.kind === "audio" ? it.kind : "file", page: String(it.page || ev.origin), from: "iframe" }));
      childItems.set(ev.origin + "|" + (d.frame || ""), clean);
      report();
    });

    browser.runtime.onMessage.addListener((msg) => {
      if (!msg || msg.type !== "vsaver-get") return;
      return Promise.resolve({
        title: document.title || location.hostname,
        page: location.href,
        ua: navigator.userAgent,
        cookie: document.cookie || "",
        items: collect(),
      });
    });
  }

  // 新しく読み込まれた通信（再生開始時など）を監視
  try {
    new PerformanceObserver((list) => {
      let hit = false;
      list.getEntries().forEach((e) => { if (MEDIA_RE.test(e.name)) { add(e.name, "network"); hit = true; } });
      if (hit) report();
    }).observe({ type: "resource", buffered: true });
  } catch (e) {}

  document.addEventListener("loadedmetadata", report, true);
  document.addEventListener("play", report, true);
  window.addEventListener("load", report);
  document.addEventListener("DOMContentLoaded", report);
})();
