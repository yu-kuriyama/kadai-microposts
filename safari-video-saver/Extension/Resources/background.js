// ページ内で見つかった動画の数をボタンのバッジに表示する
browser.runtime.onMessage.addListener((msg, sender) => {
  if (msg && msg.type === "vsaver-count" && sender.tab) {
    browser.action.setBadgeText({ tabId: sender.tab.id, text: msg.count ? String(msg.count) : "" }).catch(() => {});
  }
});
