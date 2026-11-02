// ==UserScript==
// @name         PopupKiller（しつこい広告・ポップアップ消し）
// @namespace    https://github.com/yu-kuriyama/kadai-microposts
// @version      1.0.0
// @description  何回消しても出てくるポップアップ広告・画面を覆う広告・下に張り付く広告を自動で消し続けます。iPhone の Safari（Userscripts アプリ）用。
// @author       yu-kuriyama
// @match        *://*/*
// @run-at       document-start
// @inject-into  auto
// @noframes
// @downloadURL  https://raw.githubusercontent.com/yu-kuriyama/kadai-microposts/claude/iphone-ad-blocker-app-hb99ie/ios-adblocker/popup-killer.user.js
// @updateURL    https://raw.githubusercontent.com/yu-kuriyama/kadai-microposts/claude/iphone-ad-blocker-app-hb99ie/ios-adblocker/popup-killer.user.js
// ==/UserScript==

(function () {
  'use strict';

  if (window.__popupKillerLoaded) return;
  window.__popupKillerLoaded = true;

  // document-start ではまだ <html> が無いことがあるので、できるまで待ってから本体を動かす
  if (!document.documentElement) {
    const waitRoot = new MutationObserver(() => {
      if (document.documentElement) { waitRoot.disconnect(); main(); }
    });
    waitRoot.observe(document, { childList: true });
  } else {
    main();
  }

  function main() {

  // ---------------------------------------------------------------------------
  // 設定
  // ---------------------------------------------------------------------------

  // ここに書いたサイトでは何もしない（壊れるサイトがあれば追加）
  const BUILTIN_SKIP_HOSTS = [
    'maps.google.', 'google.com/maps', 'docs.google.com', 'drive.google.com',
    'mail.google.com', 'meet.google.com', 'icloud.com', 'apple.com',
    'figma.com', 'canva.com', 'notion.so', 'claude.ai', 'chatgpt.com',
  ];

  // 広告配信ドメイン（iframe / リンク / window.open の判定に使う）
  const AD_DOMAIN_RE = new RegExp([
    'doubleclick\\.net', 'googlesyndication\\.com', 'googleadservices\\.com',
    'google_ads', 'adservice\\.google', 'amazon-adsystem\\.com', 'criteo\\.',
    'taboola\\.com', 'outbrain\\.com', 'adnxs\\.com', 'rubiconproject\\.com',
    'pubmatic\\.com', 'openx\\.net', 'smartadserver\\.com', 'yieldmo\\.com',
    'teads\\.tv', 'popads\\.net', 'popcash\\.net', 'propellerads', 'adsterra',
    'exoclick\\.com', 'juicyads\\.com', 'trafficjunky', 'onclkds', 'adcash',
    'i-mobile\\.co\\.jp', 'nend\\.net', 'adingo\\.jp', 'fluct\\.jp',
    'gsspat\\.jp', 'genieesspv\\.jp', 'geniee', 'microad\\.', 'impact-ad\\.jp',
    'ad-stir\\.com', 'adstir', 'logly\\.co\\.jp', 'popin\\.cc', 'zucks\\.net',
    'yads\\.yahoo', 'yads\\.c\\.yimg', 'ad\\.yieldmanager', 'adform\\.net',
    'unrulymedia', 'vidoomy', 'primis\\.tech', 'connatix', 'ad-generation\\.jp',
    'socdm\\.com', 'scaleout\\.jp', 'adpdx', 'ad\\.as\\.amanad', 'amoad\\.com',
  ].join('|'), 'i');

  // 見つけ次第 CSS で非表示にする広告セレクタ（確実に広告のものだけ）
  const AD_SELECTORS = [
    'ins.adsbygoogle', '.adsbygoogle', '[data-ad-client]', '[data-ad-slot]',
    '[id^="google_ads_iframe"]', '[id^="div-gpt-ad"]', '[id^="gpt_unit_"]',
    'iframe[id^="google_ads"]', 'iframe[src*="googlesyndication"]',
    'iframe[src*="doubleclick.net"]', 'iframe[src*="amazon-adsystem"]',
    'iframe[src*="i-mobile.co.jp"]', 'iframe[src*="nend.net"]',
    'iframe[src*="adingo.jp"]', 'iframe[src*="microad"]', 'iframe[src*="criteo"]',
    'iframe[src*="yads.yahoo"]', 'iframe[src*="taboola"]', 'iframe[src*="outbrain"]',
    '[id^="taboola-"]', '.trc_related_container', '.OUTBRAIN', '[data-widget-id^="AR_"]',
    '[id^="yads"]', '.yads', '[id^="ydn-"]', '.ydn-ad',
    '[id^="gn_interstitial"]', '[id^="gn_expand"]', '[class^="gn_"][class*="_ad"]',
    '[id^="im-"][id$="-ad"]', '[id^="imobile"]', '[id*="i-mobile"]', '.nend_wrapper',
    '[id^="fluct"]', '.fluct-unit', '[id^="microad"]', '.adstir',
    '.ad', '.ads', '.adsense', '.advertisement', '.ad-banner', '.ad-area', '.ad-box',
    '.ad-wrap', '.ad-wrapper', '.ad-container', '.ad-slot', '.ad-unit', '.ad_area',
    '.ad_box', '.ad_wrap', '.ad-overlay', '.ad-sticky', '.sticky-ad', '.anchor-ad',
    '.overlay-ad', '.footer-ad', '.ad-footer', '.adBanner', '.adArea', '.adBox',
    '#ad', '#ads', '#adArea', '#ad-area', '#ad_area', '#overlay-ad', '#footer-ad',
    '#sticky-ad', '#anchor-ad',
  ];

  // id / class にこの単語が入っていたら「広告っぽい」（判定材料のひとつ。単独では消さない）
  const AD_TOKEN_RE = /(^|[-_\s])(ads?|advert(isement)?|adsense|sponsor(ed)?|banner|interstitial|vignette|popunder|promo)([-_\s]|\d|$)/i;
  // こちらは「ほぼ確実に広告」の単語（banner / promo などは普通のサイトでも使うので外す）
  const STRONG_AD_TOKEN_RE = /(^|[-_\s])(ads?|advert(isement)?|adsense|sponsored|interstitial|vignette|popunder)([-_\s]|\d|$)/i;
  const CLOSE_TEXT_RE = /^(×|✕|✖|x|X|閉じる|とじる|close|閉|skip|スキップ|今はしない|あとで)$/;

  const UI_ATTR = 'data-popup-killer-ui';
  const STORE_KEY = '__popupKillerOffHosts';
  const SCAN_INTERVAL_MS = 800;
  const USER_ACTION_GRACE_MS = 1500;

  // ---------------------------------------------------------------------------
  // サイトごとの ON / OFF
  // ---------------------------------------------------------------------------
  const host = location.hostname;
  const hrefNoQuery = host + location.pathname;

  function readOffHosts() {
    try { return JSON.parse(localStorage.getItem(STORE_KEY) || '[]'); } catch (e) { return []; }
  }
  function setSiteOff(off) {
    try {
      let list = readOffHosts().filter(h => h !== host);
      if (off) list.push(host);
      localStorage.setItem(STORE_KEY, JSON.stringify(list));
    } catch (e) { /* ignore */ }
  }
  if (BUILTIN_SKIP_HOSTS.some(h => hrefNoQuery.includes(h))) return;
  if (readOffHosts().includes(host)) return;

  // ---------------------------------------------------------------------------
  // 1) 広告セレクタを CSS で即非表示（document-start で注入するのでチラつかない）
  // ---------------------------------------------------------------------------
  const style = document.createElement('style');
  style.setAttribute(UI_ATTR, 'style');
  style.textContent =
    AD_SELECTORS.join(',\n') + ' { display: none !important; visibility: hidden !important; }\n' +
    `html.pk-unlock, html.pk-unlock body { overflow: auto !important; overflow-y: auto !important; position: static !important; height: auto !important; touch-action: auto !important; }\n` +
    `html.pk-unlock body { top: auto !important; }\n`;
  (document.head || document.documentElement).appendChild(style);
  // サイト側が head を書き換えて style を消しても戻す
  function ensureStyle() {
    if (!style.isConnected) (document.head || document.documentElement).appendChild(style);
  }

  // Google の全画面広告（#google_vignette）を URL から消す
  function clearVignetteHash() {
    if (location.hash === '#google_vignette') {
      try { history.replaceState(null, '', location.href.replace(/#google_vignette$/, '')); } catch (e) { /* ignore */ }
      unlockScroll();
    }
  }

  // ---------------------------------------------------------------------------
  // 2) 広告で新しいタブを勝手に開かせない（ページ側の window.open を差し替え）
  //    CSP で弾かれるサイトでは効かないが、他の機能には影響しない
  // ---------------------------------------------------------------------------
  function patchWindowOpen() {
    const code = `(() => {
      if (window.__pkOpenPatched) return; window.__pkOpenPatched = true;
      const AD = ${AD_DOMAIN_RE.toString()};
      const orig = window.open;
      let lastOpen = 0;
      window.open = function (url, ...rest) {
        try {
          const u = String(url || '');
          const now = Date.now();
          const abs = u ? new URL(u, location.href) : null;
          const cross = abs && abs.origin !== location.origin;
          const tooFast = now - lastOpen < 1000;
          if ((abs && AD.test(abs.href)) || (cross && tooFast)) {
            console.info('[PopupKiller] window.open をブロック:', u);
            return null;
          }
          lastOpen = now;
        } catch (e) {}
        return orig.call(this, url, ...rest);
      };
    })();`;
    try {
      const s = document.createElement('script');
      s.textContent = code;
      (document.head || document.documentElement).appendChild(s);
      s.remove();
    } catch (e) { /* ignore */ }
  }
  patchWindowOpen();

  // ---------------------------------------------------------------------------
  // ユーザー操作の記録（自分でタップして開いたメニュー等は消さない）
  // ---------------------------------------------------------------------------
  let lastUserAction = 0;
  // touchstart はスクロールでも発生するので使わない（click はタップした時だけ）
  for (const ev of ['click', 'keydown', 'submit']) {
    window.addEventListener(ev, (e) => {
      if (e.target && e.target.closest && e.target.closest(`[${UI_ATTR}]`)) return;
      lastUserAction = Date.now();
    }, { capture: true, passive: true });
  }

  // ---------------------------------------------------------------------------
  // 判定ヘルパー
  // ---------------------------------------------------------------------------
  const allowed = new WeakSet();   // 消さないと決めた要素（ユーザー操作で開いた / 元に戻した）
  const firstSeen = new WeakMap(); // 要素を最初に見た時刻
  const keepCache = new WeakMap(); // 「消さない」判定のキャッシュ
  let baselineDone = false;
  const baseline = new WeakSet();  // ページを開いた時点で既にあった全画面要素（アプリ本体など）

  function vw() { return window.innerWidth || document.documentElement.clientWidth; }
  function vh() { return window.innerHeight || document.documentElement.clientHeight; }

  function isOurUI(el) { return !!(el.closest && el.closest(`[${UI_ATTR}]`)); }

  function isFixedLike(cs) { return cs.position === 'fixed' || cs.position === 'sticky'; }

  // el から上にたどって、一番外側の position:fixed / sticky な要素を返す
  function outermostFixed(el) {
    let found = null;
    for (let n = el; n && n !== document.body && n !== document.documentElement; n = n.parentElement) {
      const cs = getComputedStyle(n);
      if (cs.position === 'fixed' || (cs.position === 'sticky' && n.getBoundingClientRect().height < vh() * 0.4)) found = n;
    }
    return found;
  }

  function visibleRect(el) {
    const r = el.getBoundingClientRect();
    const left = Math.max(0, r.left), top = Math.max(0, r.top);
    const right = Math.min(vw(), r.right), bottom = Math.min(vh(), r.bottom);
    const w = Math.max(0, right - left), h = Math.max(0, bottom - top);
    return { left, top, right, bottom, w, h, area: w * h, raw: r };
  }

  function tokenOf(el) {
    const cls = typeof el.className === 'string' ? el.className : (el.getAttribute && el.getAttribute('class')) || '';
    return (el.id || '') + ' ' + cls;
  }

  function isAdIframe(f) {
    const src = (f.getAttribute('src') || '') + ' ' + (f.id || '') + ' ' + (f.name || '');
    return AD_DOMAIN_RE.test(src);
  }

  function adDescendants(el) {
    const out = [];
    try {
      el.querySelectorAll('iframe').forEach(f => { if (isAdIframe(f)) out.push(f); });
      el.querySelectorAll(AD_SELECTORS.join(',')).forEach(n => out.push(n));
    } catch (e) { /* ignore */ }
    return out;
  }

  function isAdLike(el) {
    if (STRONG_AD_TOKEN_RE.test(tokenOf(el))) return true;
    try { if (el.matches(AD_SELECTORS.join(','))) return true; } catch (e) { /* ignore */ }
    if (el.tagName === 'IFRAME' && isAdIframe(el)) return true;
    return false;
  }

  function hasExternalImageLink(el) {
    for (const a of el.querySelectorAll('a[href]')) {
      try {
        const u = new URL(a.href, location.href);
        if (u.hostname && u.hostname !== host && !u.hostname.endsWith('.' + host.split('.').slice(-2).join('.'))) {
          if (a.querySelector('img, picture, video, canvas, svg') || AD_DOMAIN_RE.test(u.href)) return true;
        }
      } catch (e) { /* ignore */ }
    }
    return false;
  }

  function textLen(el) {
    return ((el.innerText || el.textContent || '').replace(/\s+/g, '')).length;
  }

  function hasCloseButton(el) {
    for (const b of el.querySelectorAll('button, a, span, div, i')) {
      const t = (b.textContent || '').trim();
      if (t.length <= 6 && CLOSE_TEXT_RE.test(t)) return true;
      const lbl = (b.getAttribute('aria-label') || '') + ' ' + tokenOf(b);
      if (/close|閉じる|dismiss/i.test(lbl)) return true;
    }
    return false;
  }

  function isSemiTransparentBackdrop(el) {
    const cs = getComputedStyle(el);
    const m = cs.backgroundColor.match(/rgba?\(([^)]+)\)/);
    if (m) {
      const parts = m[1].split(/[,\s/]+/).filter(Boolean).map(Number);
      if (parts.length === 4 && parts[3] > 0 && parts[3] < 0.95) return true;
    }
    if (parseFloat(cs.opacity) < 0.95 && parseFloat(cs.opacity) > 0) return true;
    if (cs.backdropFilter && cs.backdropFilter !== 'none') return true;
    if (cs.webkitBackdropFilter && cs.webkitBackdropFilter !== 'none') return true;
    return false;
  }

  function isScrollLocked() {
    const h = getComputedStyle(document.documentElement);
    const b = document.body ? getComputedStyle(document.body) : null;
    return h.overflow === 'hidden' || h.overflowY === 'hidden' ||
      (b && (b.overflow === 'hidden' || b.overflowY === 'hidden' || b.position === 'fixed'));
  }

  function unlockScroll() {
    document.documentElement.classList.add('pk-unlock');
  }

  // ---------------------------------------------------------------------------
  // 判定本体：この固定要素を消すべきか？
  //   'remove'       … 要素ごと消す
  //   'strip'        … 中の広告部分だけ消す
  //   null           … 何もしない
  // ---------------------------------------------------------------------------
  function judge(el) {
    if (!el || el === document.body || el === document.documentElement) return null;
    if (allowed.has(el) || isOurUI(el)) return null;
    if (el.tagName === 'VIDEO' || document.fullscreenElement || document.webkitFullscreenElement) return null;
    if (el.querySelector('input:focus, textarea:focus, select:focus, [contenteditable="true"]:focus')) return null;

    const now = Date.now();
    if (!firstSeen.has(el)) firstSeen.set(el, now);

    // 前回「消さない」と判定して中身も変わっていなければ、しばらく再判定しない（軽くするため）
    const sig = el.childElementCount + ':' + el.getBoundingClientRect().height + ':' + isScrollLocked();
    const c = keepCache.get(el);
    if (c && c.sig === sig && now - c.t < 4000) return null;
    const v = judgeInner(el, now);
    if (!v) keepCache.set(el, { sig, t: now });
    return v;
  }

  function judgeInner(el, now) {
    const r = visibleRect(el);
    if (r.w < 2 || r.h < 2) return null;
    const viewArea = vw() * vh();
    const areaRatio = r.area / viewArea;
    const tl = textLen(el);
    const adLike = isAdLike(el);
    const adKids = adDescendants(el);
    const hasAdIframe = adKids.length > 0;

    // 自分でタップした直後に出たもの（メニュー・ログイン画面など）は、明らかな広告以外は残す
    const userInitiated = firstSeen.get(el) - lastUserAction < USER_ACTION_GRACE_MS && firstSeen.get(el) >= lastUserAction;
    if (userInitiated && !adLike && !hasAdIframe) { allowed.add(el); return null; }

    // A. 明らかな広告（広告ネットワークの iframe / 広告セレクタ）
    if (adLike && (areaRatio > 0.02 || hasAdIframe)) return 'remove';
    if (hasAdIframe) {
      // 固定ヘッダーに広告が埋まっているだけなら、広告部分だけ抜く
      return tl > 80 ? 'strip' : 'remove';
    }

    // B. 画面を覆うオーバーレイ（ポップアップ広告・アドブロック検出・登録しろ画面など）
    if (areaRatio >= 0.3) {
      // ページを開いた時点で既にあった、不透明でスクロールも止めていない全画面要素はアプリ本体とみなす
      if (baseline.has(el) && !isSemiTransparentBackdrop(el) && !isScrollLocked() && !hasCloseButton(el)) return null;
      if (tl > 3000) return null; // 文章がたっぷり入っている＝本文
      const signals =
        (isSemiTransparentBackdrop(el) ? 1 : 0) +
        (isScrollLocked() ? 1 : 0) +
        (hasCloseButton(el) ? 1 : 0) +
        (tl < 400 ? 1 : 0) +
        (hasExternalImageLink(el) ? 1 : 0) +
        (AD_TOKEN_RE.test(el.innerHTML.slice(0, 4000)) ? 1 : 0);
      if (tl === 0 && areaRatio >= 0.6) return 'remove'; // 透明な全画面リンク（タップすると広告に飛ぶやつ）
      if (signals >= 2) return 'remove';
      return null;
    }

    // C. 画面の上下に張り付くバナー
    const atBottom = r.raw.bottom >= vh() - 4 && r.raw.top > vh() * 0.5;
    const atTop = r.raw.top <= 4 && r.raw.bottom < vh() * 0.5;
    if ((atBottom || atTop) && r.h <= vh() * 0.35 && r.w >= vw() * 0.5) {
      if (hasExternalImageLink(el) && tl < 60) return 'remove';
      if (el.querySelector('iframe') && tl < 60) return 'remove';
      return null;
    }

    // D. 角に浮いている小さい動画広告など
    if (areaRatio < 0.3 && el.querySelector('iframe, video') && (AD_TOKEN_RE.test(el.innerHTML.slice(0, 3000)) || hasExternalImageLink(el)) && tl < 60) {
      return 'remove';
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // 消す / 元に戻す
  // ---------------------------------------------------------------------------
  const removedLog = []; // { el, parent, next }
  let blockedCount = 0;

  function removeEl(el) {
    removedLog.push({ el, parent: el.parentNode, next: el.nextSibling });
    if (removedLog.length > 30) removedLog.shift();
    el.remove();
    blockedCount++;
  }

  function act(el, verdict) {
    if (verdict === 'remove') {
      const wasLocked = isScrollLocked();
      removeEl(el);
      if (wasLocked) unlockScroll();
      return true;
    }
    if (verdict === 'strip') {
      adDescendants(el).forEach(removeEl);
      return true;
    }
    return false;
  }

  function undoLast() {
    const items = removedLog.splice(0);
    for (const it of items.reverse()) {
      try {
        allowed.add(it.el);
        if (it.parent && it.parent.isConnected) it.parent.insertBefore(it.el, it.next && it.next.parentNode === it.parent ? it.next : null);
      } catch (e) { /* ignore */ }
    }
    document.documentElement.classList.remove('pk-unlock');
  }

  // ---------------------------------------------------------------------------
  // スキャン：画面上のいくつかの点で「一番上にある要素」を調べる（軽い）
  // ---------------------------------------------------------------------------
  function samplePoints() {
    const w = vw(), h = vh();
    return [
      [w * 0.5, h * 0.5], [w * 0.5, h * 0.3], [w * 0.5, h * 0.7], [w * 0.2, h * 0.5], [w * 0.8, h * 0.5],
      [w * 0.5, h - 6], [w * 0.15, h - 6], [w * 0.85, h - 6], [w * 0.5, h - 40],
      [w * 0.5, 6], [w * 0.15, 6], [w * 0.85, 6],
      [w - 20, h - 80], [20, h - 80], [w - 20, h * 0.75],
    ];
  }

  function takeBaseline() {
    if (baselineDone || !document.body) return;
    baselineDone = true;
    for (const [x, y] of samplePoints()) {
      const top = document.elementFromPoint(x, y);
      if (!top) continue;
      const f = outermostFixed(top);
      if (f && visibleRect(f).area / (vw() * vh()) > 0.85 && !isAdLike(f)) baseline.add(f);
    }
  }

  function scan() {
    if (!document.body) return;
    ensureStyle();
    clearVignetteHash();
    let changed = false;
    for (const [x, y] of samplePoints()) {
      // 重なっている場合があるので同じ点を数回見る
      for (let i = 0; i < 4; i++) {
        const top = document.elementFromPoint(x, y);
        if (!top || isOurUI(top)) break;
        const f = outermostFixed(top);
        if (!f) break;
        const v = judge(f);
        if (!v || !act(f, v)) break;
        changed = true;
      }
    }
    // 広告セレクタに当たった要素は CSS で消えているが、スクロールロックだけ残ることがあるので解除
    if (document.querySelector('ins.adsbygoogle[data-vignette-loaded="true"], [id^="gn_interstitial"]')) unlockScroll();
    if (changed) showToast();
  }

  // ---------------------------------------------------------------------------
  // 小さな通知（元に戻す / このサイトでOFF）
  // ---------------------------------------------------------------------------
  let toast, toastTimer;
  function showToast() {
    if (!document.body) return;
    if (!toast) {
      toast = document.createElement('div');
      toast.setAttribute(UI_ATTR, 'toast');
      toast.attachShadow({ mode: 'open' }).innerHTML = `
        <style>
          .box { position: fixed; left: 50%; bottom: calc(14px + env(safe-area-inset-bottom)); transform: translateX(-50%);
                 z-index: 2147483647; display: flex; align-items: center; gap: 10px; padding: 8px 10px 8px 14px;
                 background: rgba(20,20,22,.97); color: #fff; border-radius: 999px; font: 13px/1.2 -apple-system, system-ui, sans-serif;
                 box-shadow: 0 4px 18px rgba(0,0,0,.3); white-space: nowrap; -webkit-backdrop-filter: blur(8px); }
          button { all: unset; cursor: pointer; padding: 5px 9px; border-radius: 999px; background: rgba(255,255,255,.14); font-size: 12px; }
          button:active { background: rgba(255,255,255,.3); }
        </style>
        <div class="box"><span id="msg"></span><button id="undo">元に戻す</button><button id="off">このサイトOFF</button></div>`;
      const root = toast.shadowRoot;
      root.getElementById('undo').addEventListener('click', () => { undoLast(); hideToast(); });
      root.getElementById('off').addEventListener('click', () => {
        setSiteOff(true); undoLast(); stopped = true; style.remove(); hideToast();
        alert('このサイトでは PopupKiller をOFFにしました。\nページを再読み込みすると元に戻ります。\n（ONに戻すには Safari の「履歴とWebサイトデータを消去」かスクリプトの設定から）');
      });
    }
    toast.shadowRoot.getElementById('msg').textContent = `🛡️ ${blockedCount}件ブロック`;
    if (!toast.isConnected) document.documentElement.appendChild(toast);
    clearTimeout(toastTimer);
    toastTimer = setTimeout(hideToast, 3500);
  }
  function hideToast() { if (toast) toast.remove(); }

  // ---------------------------------------------------------------------------
  // 起動：DOM の変化を見張る＋定期チェック（何回出てきても消す）
  // ---------------------------------------------------------------------------
  let stopped = false;
  let pending = false;
  function schedule() {
    if (pending || stopped) return;
    pending = true;
    (window.requestAnimationFrame || setTimeout)(() => { pending = false; if (!stopped) scan(); });
  }

  const mo = new MutationObserver(schedule);
  mo.observe(document.documentElement, { childList: true, subtree: true });

  function start() {
    takeBaseline();
    scan();
    setInterval(() => { if (!stopped && !document.hidden) scan(); }, SCAN_INTERVAL_MS);
    window.addEventListener('scroll', schedule, { passive: true });
    window.addEventListener('resize', schedule, { passive: true });
    window.addEventListener('hashchange', schedule);
  }
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start, { once: true });
  } else {
    start();
  }

  // テスト用に中身を公開
  window.__popupKiller = { scan, judge, undoLast, get blocked() { return blockedCount; } };
  } // main
})();
