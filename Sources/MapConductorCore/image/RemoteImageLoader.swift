import Foundation
import UIKit

/// URL で渡された画像（``ImageIcon/init(imageUrl:iconSize:scale:anchor:infoAnchor:debug:label:labelTextColor:labelTextSize:labelTypeFace:labelStrokeColor:labelPosition:labelWritingMode:)``、
/// ``GroundImageState/init(bounds:imageUrl:opacity:tileSize:id:extra:onClick:)``）を読み込む。
///
/// - 同じ URL は 1 度しか取りに行かない。読み込み中に何度頼まれても、終わったときに
///   全員へ知らせる。
/// - 読み終えた画像は `NSCache` に置く。追い出されても、すでに受け取ったアイコンや
///   地表画像は自分で画像を持っているので困らない。後から作ったものが取り直すだけ。
/// - 失敗も覚えておき、同じ URL で何度も取りに行かない。ログは URL ごとに 1 度だけ。
/// - 知らせ（`whenSettled` に渡したクロージャ）はメインスレッドで、1 度だけ呼ぶ。
///
/// android-sdk / js-sdk-core にも同じ役割のローダーがある。
final class RemoteImageLoader {
    enum Status {
        case pending
        case ready(UIImage)
        case failed
    }

    /// 取りに行く処理。テストで差し替える。結果は任意のスレッドで返してよい。
    typealias Fetch = (URL, @escaping (Data?) -> Void) -> Void

    static let shared = RemoteImageLoader()

    private let fetch: Fetch
    private let lock = NSLock()
    private let images = NSCache<NSURL, UIImage>()
    private var failed = Set<URL>()
    private var waiting: [URL: [(UIImage?) -> Void]] = [:]

    init(fetch: @escaping Fetch = RemoteImageLoader.urlSessionFetch) {
        self.fetch = fetch
        images.countLimit = 256
    }

    /// 今の状態。まだ取りに行っていなければ取りに行く。
    func status(_ url: URL) -> Status {
        lock.lock()
        if let image = images.object(forKey: url as NSURL) {
            lock.unlock()
            return .ready(image)
        }
        if failed.contains(url) {
            lock.unlock()
            return .failed
        }
        let start = waiting[url] == nil
        if start { waiting[url] = [] }
        lock.unlock()
        if start { begin(url) }
        return .pending
    }

    /// 読み込みが終わったら `callback` を呼ぶ（失敗なら nil）。
    ///
    /// すでに終わっていれば何もせず false を返す（呼び出し側はそのときの `status` を使う）。
    /// 状態を確かめてから登録するまでの間に終わることはない（同じ鍵の中で行う）。
    @discardableResult
    func whenSettled(_ url: URL, _ callback: @escaping (UIImage?) -> Void) -> Bool {
        lock.lock()
        if images.object(forKey: url as NSURL) != nil || failed.contains(url) {
            lock.unlock()
            return false
        }
        let start = waiting[url] == nil
        waiting[url, default: []].append(callback)
        lock.unlock()
        if start { begin(url) }
        return true
    }

    private func begin(_ url: URL) {
        fetch(url) { [weak self] data in
            let image = data.flatMap { UIImage(data: $0) }
            self?.settle(url, image: image)
        }
    }

    private func settle(_ url: URL, image: UIImage?) {
        lock.lock()
        if let image {
            images.setObject(image, forKey: url as NSURL)
        } else {
            failed.insert(url)
        }
        let callbacks = waiting.removeValue(forKey: url) ?? []
        lock.unlock()
        if image == nil {
            NSLog("[MapConductor] Failed to load image: %@", url.absoluteString)
        }
        let deliver = {
            for callback in callbacks { callback(image) }
        }
        if Thread.isMainThread { deliver() } else { DispatchQueue.main.async(execute: deliver) }
    }

    static func urlSessionFetch(_ url: URL, _ completion: @escaping (Data?) -> Void) {
        URLSession.shared.dataTask(with: url) { data, response, _ in
            if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                completion(nil)
                return
            }
            completion(data)
        }.resume()
    }
}
