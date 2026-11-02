# 動画保存（Safari 拡張機能）

iPhone の Safari で動画を見ているときに、そのままダウンロードして写真アプリに保存できるアプリです。

## 使い方

1. Safari で動画のページを開きます。動画が出てこないときは、一度再生してください。
2. アドレスバー左のボタン（ぁあ / ページメニュー）から「**動画保存**」を押します。
3. 見つかった動画が一覧で出るので、「**保存する**」を押します。
4. 「動画保存」アプリが開いてダウンロードが始まり、終わると**写真アプリに自動で保存**されます。
   Safari に戻っても、ダウンロードは続きます。

## できること・できないこと

| 種類 | 対応 |
|---|---|
| ページ内の普通の動画（mp4 / mov / webm） | ○ |
| ストリーミング動画（HLS / m3u8）。多くの動画サイト・ニュースサイトが使用 | ○（自動で mp4 に変換） |
| iframe（埋め込みプレーヤー）の中の動画 | ○ |
| YouTube / X / Instagram など、動画を細切れにして組み立てる仕組みのサイト | ×（今後の追加候補） |
| Netflix などの DRM（コピー防止）付き動画 | ×（対応しません） |

webm などの写真アプリが対応していない形式は、「ファイル」アプリ →「このiPhone内」→「動画保存」に保存されます。

---

## iPhone に入れる方法

### 方法A：Mac がある場合

```sh
brew install xcodegen
cd safari-video-saver
xcodegen generate
open VideoSaver.xcodeproj
```

1. Xcode でプロジェクト設定 → Signing & Capabilities を開き、両方のターゲット（VideoSaver / VideoSaverExtension）の Team に自分のアカウントを選びます。
2. `project.yml` の `BUNDLE_PREFIX` を自分用（例：`com.あなたの名前.videosaver`）に変えます。
3. iPhone をケーブルでつないで ▶︎ を押せばインストールされます。

### 方法B：Mac がない場合（GitHub でビルド → TestFlight）

このリポジトリに push すると、GitHub の Mac サーバーが自動でビルドします（`.github/workflows/safari-video-saver.yml`）。
次の設定を最初に一度だけ行えば、TestFlight アプリから iPhone にインストールできるようになります。

**1. App Store Connect の API キーを作る**
- [App Store Connect](https://appstoreconnect.apple.com/) →「ユーザとアクセス」→「統合」→「App Store Connect API」→「チームキー」で「＋」を押します。
- アクセス権は **Admin** にします（証明書を自動で作るために必要です）。
- 次の3つを控えます。
  - **Issuer ID**
  - **キーID**
  - ダウンロードした **AuthKey_XXXX.p8** ファイル（一度しかダウンロードできません）

**2. アプリIDを登録して、アプリを作る**
- [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list) →「＋」→「App IDs」→「App」を選び、Bundle ID に `com.あなたの名前.videosaver` のような ID を入れて登録します。
- App Store Connect →「アプリ」→「＋」→「新規App」で、プラットフォーム iOS、名前「動画保存」（使えなければ別の名前）、さきほどの Bundle ID を選んで作成します。審査には出しません。

**3. GitHub に Secrets を登録する**
リポジトリの Settings → Secrets and variables → Actions →「New repository secret」で、次の5つを登録します。

| 名前 | 中身 |
|---|---|
| `ASC_KEY_ID` | キーID |
| `ASC_ISSUER_ID` | Issuer ID |
| `ASC_KEY_P8` | AuthKey_XXXX.p8 をテキストエディタで開いた中身すべて |
| `APPLE_TEAM_ID` | [メンバーシップ](https://developer.apple.com/account) ページの「チームID」（10文字） |
| `BUNDLE_ID` | 2 で登録した Bundle ID |

**4. ビルドを実行する**
GitHub の Actions タブ →「Safari動画保存アプリ」→「Run workflow」を押します（または何かを push します）。
15〜30分ほどで App Store Connect の TestFlight に出てきます。

**5. iPhone に入れる**
- App Store から「**TestFlight**」アプリを入れます。
- App Store Connect → 作ったアプリ →「TestFlight」→「内部テスト」でグループを作り、自分を追加します。
- iPhone に届く招待から、TestFlight 経由でインストールします。

> TestFlight のビルドは90日で期限が切れます。切れる前に「Run workflow」をもう一度押してください。

## iPhone での最初の設定

1. 「設定」アプリ →「アプリ」→「Safari」→「機能拡張」→「**動画保存**」をオンにします。
2. 「すべてのWebサイト」を「**許可**」にします。
3. 最初の保存時に「写真へのアクセス」を聞かれたら許可します。

## しくみ（開発メモ）

- `Extension/Resources/content.js`：ページ内の `<video>`、通信の記録（Resource Timing）、HTML 内の URL、og:video、iframe の中を調べて動画の URL を集めます。細切れのパーツ（セグメント）は除外します。
- `Extension/Resources/popup.*`：見つかった動画の一覧を表示し、`videosaver://add?d=…` でアプリに URL・Referer・User-Agent・Cookie を渡します。
- `App/DownloadManager.swift`：background URLSession でダウンロードするので、アプリを閉じても続きます。HLS は `AVAssetDownloadURLSession` で保存してから mp4 に書き出し、写真アプリに保存します。
