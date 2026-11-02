const $ = (s) => document.querySelector(s);
const LABEL = { hls: "ストリーム", file: "動画", audio: "音声" };
let page = null;
let tabId = null;

function b64url(str) {
  const bytes = new TextEncoder().encode(str);
  let bin = "";
  bytes.forEach((b) => (bin += String.fromCharCode(b)));
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function baseDomain(host) {
  return host.split(".").slice(-2).join(".");
}

// アプリ「動画保存」を開いてダウンロードを始める
function openInApp(item) {
  const media = new URL(item.url);
  const pageUrl = new URL(item.page || page.page);
  const sameSite = baseDomain(media.hostname) === baseDomain(new URL(page.page).hostname);
  const payload = {
    u: item.url,
    k: item.kind === "hls" ? "hls" : "file",
    t: page.title,
    ref: pageUrl.href,
    ua: page.ua,
    c: sameSite ? page.cookie.slice(0, 3000) : "",
  };
  const appUrl = "videosaver://add?d=" + b64url(JSON.stringify(payload));
  browser.tabs.update(tabId, { url: appUrl }).catch(() => { location.href = appUrl; });
  setTimeout(() => window.close(), 300);
}

function fileName(url) {
  try {
    const u = new URL(url);
    const last = decodeURIComponent(u.pathname.split("/").filter(Boolean).pop() || u.hostname);
    return last.length > 60 ? last.slice(0, 57) + "…" : last;
  } catch (e) { return url; }
}

function render() {
  const list = $("#list");
  list.innerHTML = "";
  const items = page ? page.items : [];
  $("#hint").hidden = false;
  if (!items.length) {
    $("#status").textContent = "";
    list.innerHTML = `<li class="empty"><div class="big">🎬</div>このページでは動画が見つかりませんでした。</li>`;
    return;
  }
  $("#status").textContent = `${items.length}件の動画が見つかりました`;
  items.forEach((it, i) => {
    const li = document.createElement("li");
    const host = new URL(it.url).hostname;
    li.innerHTML = `
      <div class="top"><span class="tag ${it.kind}">${LABEL[it.kind] || "動画"}</span><span class="name"></span></div>
      <div class="host"></div>
      <div class="btns"><button class="save">${i === 0 ? "保存する（おすすめ）" : "保存する"}</button><button class="copy">URL</button></div>`;
    li.querySelector(".name").textContent = fileName(it.url);
    li.querySelector(".host").textContent = host;
    li.querySelector(".save").onclick = () => openInApp(it);
    li.querySelector(".copy").onclick = async (e) => {
      try { await navigator.clipboard.writeText(it.url); e.target.textContent = "コピー済"; } catch (err) { e.target.textContent = "失敗"; }
    };
    list.appendChild(li);
  });
}

async function load() {
  $("#status").textContent = "探しています…";
  try {
    const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
    tabId = tab.id;
    page = await browser.tabs.sendMessage(tab.id, { type: "vsaver-get" });
    if (!page) throw new Error("no response");
  } catch (e) {
    page = null;
    $("#status").textContent = "";
    $("#list").innerHTML = `<li class="empty"><div class="big">🔒</div>このサイトで拡張機能が許可されていません。<br>Safariの拡張機能メニューから「動画保存」を<strong>「常に許可」</strong>にしてください。</li>`;
    return;
  }
  render();
}

$("#reload").onclick = load;
load();
