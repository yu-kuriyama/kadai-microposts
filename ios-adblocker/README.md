# PopupKiller — iPhone 用・しつこい広告消し

何回消しても出てくるポップアップ広告、画面全体を覆う広告、画面の下に張り付く広告などを、**Safari で自動的に消し続ける**スクリプトです。
無料アプリ「Userscripts」に入れて使います。Mac も開発者登録もいりません。

## 消せるもの
- 何回閉じても出てくるポップアップ（MutationObserver で見張り、出た瞬間に消します）
- 画面全体を覆う広告、「広告ブロッカーを切ってください」の壁、登録を迫る画面
- 画面の下や上に張り付く広告バナー
- どこを触っても広告に飛ばされる透明な全画面リンク
- Google の全画面広告（`#google_vignette`）、AdSense、GPT、Taboola、Outbrain、i-mobile、nend、fluct、Geniee、YDA などの広告枠
- 広告サイトを勝手に新しいタブで開く `window.open`
- ポップアップのせいでスクロールできなくなった状態（自動で解除します）

**消さないもの：** 自分でタップして開いたメニューやログイン画面、普通のヘッダーやタブバー、地図アプリのような全画面のアプリ画面

## iPhone への入れ方（5分）

1. App Store で **「Userscripts」**（開発者：Justin Wasack、無料）を入れる
2. **設定 → アプリ → Safari → 機能拡張 → Userscripts** をオンにし、「すべてのWebサイト」を「許可」にする
   （iOS 17 以前は **設定 → Safari → 機能拡張**）
3. Userscripts アプリを一度開き、保存先フォルダを決める（初期設定のままでOK）
4. **iPhone の Safari** で、下のリンクを開く
   👉 https://raw.githubusercontent.com/yu-kuriyama/kadai-microposts/claude/iphone-ad-blocker-app-hb99ie/ios-adblocker/popup-killer.user.js
5. アドレスバーの左にある「ぁあ」（またはパズルのアイコン）をタップ → **Userscripts** → **「Install」** をタップ
6. 完了。広告を消すと画面の下に「🛡️ ○件ブロック」と出ます

### 手順4〜5がうまくいかないとき
Safari で適当なページを開く → 「ぁあ」 → Userscripts → **「＋」→「New JS」** → 中身を全部消して `popup-killer.user.js` の内容を貼り付け → 保存

## 使い方
- 何もしなくてOKです。開いたページで自動的に動きます
- 必要なものまで消えた → 下に出る **「元に戻す」** をタップ
- そのサイトでは使いたくない → **「このサイトOFF」** をタップ
- 必ず除外したいサイトは、スクリプト冒頭の `BUILTIN_SKIP_HOSTS` に追加する

## 限界（iPhone の仕組み上のもの）
- 効くのは **Safari だけ**です。iPhone 版の Chrome や、Instagram・X などのアプリ内ブラウザでは動きません
- アプリ内の広告まで止めたいなら、**DNS ブロック**（AdGuard DNS や NextDNS の構成プロファイルを入れる）を併用してください

## テスト（開発者向け）
```sh
node ios-adblocker/test/run.js   # Playwright を使い、iPhone サイズの画面で広告ページと普通のページを自動チェック
```
