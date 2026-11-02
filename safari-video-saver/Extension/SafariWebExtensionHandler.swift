import Foundation
import SafariServices

/// Safari 拡張機能とアプリの橋渡し（今は応答を返すだけ。ダウンロードはアプリ側で行う）
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: ["ok": true]]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}
