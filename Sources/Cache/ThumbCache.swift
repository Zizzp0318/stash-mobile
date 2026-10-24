import SwiftUI
import UIKit

/// 缩略图两级缓存：内存（NSCache，自动响应内存警告）+ 磁盘 LRU（按 hash 命名）。
///
/// 为什么不用 `AsyncImage`：它每次重建视图都会重新发请求，滚动时缩略图会「闪一下」；
/// 而且完全没有磁盘层，切到地铁/断网就全是灰块。素材库这种「反复回看同一批图」的场景，
/// 磁盘缓存带来的体感差别非常大。
actor ThumbCache {
    static let shared = ThumbCache()

    private let memory = NSCache<NSString, UIImage>()
    private let dir: URL
    private var inflight: [String: Task<UIImage?, Never>] = [:]

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        dir = caches.appendingPathComponent("thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        memory.countLimit = 400
    }

    func image(for url: URL, key: String) async -> UIImage? {
        if let hit = memory.object(forKey: key as NSString) { return hit }
        // 同一个 key 并发请求时复用同一个 Task，避免一屏 20 张图发 20 个重复请求
        if let t = inflight[key] { return await t.value }

        let task = Task<UIImage?, Never> { [dir] in
            let file = dir.appendingPathComponent(Self.fileName(key))
            if let data = try? Data(contentsOf: file), let img = UIImage(data: data) {
                return img
            }
            guard let (data, resp) = try? await URLSession.shared.data(from: url),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let img = UIImage(data: data) else { return nil }
            try? data.write(to: file, options: .atomic)
            return img
        }
        inflight[key] = task
        let img = await task.value
        inflight[key] = nil
        if let img { memory.setObject(img, forKey: key as NSString) }
        return img
    }

    /// key 里有 `/`（如 `abc.../grid`），不能直接当文件名
    private static func fileName(_ key: String) -> String {
        key.replacingOccurrences(of: "/", with: "_")
    }

    func clearDisk() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        memory.removeAllObjects()
    }

    func diskUsage() -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return files.reduce(Int64(0)) { sum, f in
            let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return sum + Int64(size)
        }
    }
}

/// 带磁盘缓存的缩略图。加载失败显示类型图标（和桌面端的占位规则一致）。
struct CachedThumb: View {
    let url: URL?
    let cacheKey: String
    let fallbackSymbol: String

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color(white: 0.09)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if failed {
                Image(systemName: fallbackSymbol)
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Color(white: 0.42))
            } else {
                ProgressView().controlSize(.small).tint(Color(white: 0.45))
            }
        }
        .clipped()
        .task(id: cacheKey) {
            guard image == nil, let url else { return }
            let img = await ThumbCache.shared.image(for: url, key: cacheKey)
            if img == nil { failed = true } else { image = img }
        }
    }
}
