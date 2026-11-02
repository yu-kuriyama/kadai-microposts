// iPhone サイズの画面でテストページを開いて、広告が消えるか・普通の要素が残るかを確認する
const { chromium, devices } = require('playwright');
const path = require('path');
const fs = require('fs');
const script = fs.readFileSync(path.join(__dirname, '..', 'popup-killer.user.js'), 'utf8');
const url = f => 'file://' + path.join(__dirname, f);
let fail = 0;
const check = (ok, msg) => { console.log((ok ? '  ✅ ' : '  ❌ ') + msg); if (!ok) fail++; };
const wait = ms => new Promise(r => setTimeout(r, ms));

(async () => {
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ ...devices['iPhone 13'] });
  await ctx.route(/^https?:/, r => r.fulfill({ status: 200, contentType: 'text/html', body: '<html><body>ad</body></html>' }));
  await ctx.addInitScript(script);

  console.log('■ 広告だらけページ');
  let page = await ctx.newPage();
  const errs = []; page.on('pageerror', e => errs.push(e.message));
  await page.goto(url('ads.html'));
  await wait(3500);
  const st = await page.evaluate(() => ({
    nag: !!document.getElementById('nag'), shown: window.popupShown,
    anchor: !!document.getElementById('anchor'), clickjack: !!document.getElementById('clickjack'),
    adwall: !!document.getElementById('adwall'), header: !!document.getElementById('site-header'),
    insHidden: getComputedStyle(document.getElementById('ins-ad')).display === 'none',
    inlineHidden: getComputedStyle(document.getElementById('inline-ad')).display === 'none',
    scrollOk: getComputedStyle(document.documentElement).overflow !== 'hidden' && getComputedStyle(document.body).overflow !== 'hidden',
    blocked: window.__popupKiller && window.__popupKiller.blocked,
  }));
  check(!st.nag && st.shown >= 3, `しつこいポップアップを毎回消す（${st.shown}回出現→今は表示なし）`);
  check(!st.anchor, '下に張り付く広告（iframe）を消す');
  check(!st.clickjack, '透明な全画面リンクを消す');
  check(!st.adwall, 'アドブロック検出の壁を消す');
  check(st.insHidden && st.inlineHidden, '本文中の広告枠を非表示');
  check(st.scrollOk, 'スクロール禁止を解除');
  check(st.header, '固定ヘッダー（ナビ）は残す');
  // window.open で広告ドメインを開かせない
  const opened = await page.evaluate(() => window.open('https://popads.net/pop') === null);
  check(opened, '広告ドメインへの window.open をブロック');
  // スクロールできる
  await page.evaluate(() => window.scrollTo(0, 800)); await wait(100);
  check(await page.evaluate(() => window.scrollY > 500), '実際にスクロールできる');
  check(errs.length === 0, 'スクリプトエラーなし ' + errs.join(' | '));
  await page.screenshot({ path: path.join(require('os').tmpdir(), 'popup-killer-shot.png') });

  console.log('■ 普通のサイト（消してはいけないもの）');
  page = await ctx.newPage();
  await page.goto(url('legit.html'));
  await wait(1500);
  let s2 = await page.evaluate(() => ({
    banner: !!document.getElementById('banner'), hdr: !!document.getElementById('hdr'), tab: !!document.getElementById('tabbar'),
  }));
  check(s2.banner, 'サイトのお知らせバー（class=site-banner）は残す');
  check(s2.hdr, 'sticky ヘッダーは残す');
  check(s2.tab, '下のタブバーは残す');
  await page.tap('#menu-btn');
  await wait(2500);
  const drawer = await page.evaluate(() => { const d = document.getElementById('drawer'); return !!d && getComputedStyle(d).display === 'block'; });
  check(drawer, '自分でタップして開いたメニュー（全画面＋背景暗い）は残す');
  // メニューを開いたままスクロールして放置しても消えない
  await page.mouse.wheel(0, 300); await wait(1500);
  check(await page.evaluate(() => !!document.getElementById('drawer')), 'しばらく経ってもメニューは残る');

  console.log('■ 地図アプリ風（全画面アプリ）');
  page = await ctx.newPage();
  await page.goto(url('appshell.html'));
  await wait(1500);
  check(await page.evaluate(() => !!document.getElementById('app')), '全画面アプリ本体は残す');

  await browser.close();
  console.log(fail ? `\n${fail} 件失敗` : '\nすべて成功');
  process.exit(fail ? 1 : 0);
})();
