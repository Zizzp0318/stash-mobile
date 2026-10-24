import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    let connection = ConnectionStore()
    let library = LibraryStore()
    let uploads = UploadQueue()

    /// 连接变化后把 client 交给下层。
    /// 为什么不在 ConnectionStore 里直接持有 library：那会变成 Controller 互相引用，
    /// 而这套东西只有「谁拿 client」一条依赖，用显式的 bind 最不容易写出循环。
    func bind() {
        library.attach(connection.client)
        uploads.attach(connection.client)
    }
}

// MARK: - 连接

@MainActor
@Observable
final class ConnectionStore {
    private(set) var endpoint: ServerEndpoint?
    private(set) var client: APIClient?
    private(set) var libraryName: String?
    private(set) var writeAllowed = false
    private(set) var isConnected = false
    private(set) var recent: [ServerEndpoint] = []
    /// 每次连接成功 +1。视图拿它当 `.task(id:)` 的触发器 —— 比监听一堆布尔量可靠
    private(set) var epoch = 0
    var lastError: String?
    var busy = false

    private let tokenKey = "stash_token"
    private let lastKey = "stash_last_endpoint"
    private let recentKey = "stash_recent_endpoints"

    init() {
        recent = Self.loadRecent(recentKey)
        if let s = UserDefaults.standard.string(forKey: lastKey),
           let ep = ServerEndpoint.parse(s) {
            endpoint = ep
        }
    }

    /// 冷启动：拿上次的地址 + Keychain 里的 token 直接连，连不上就停在连接页并给出原因
    func restore() async {
        guard let ep = endpoint, let token = Keychain.get(tokenKey) else { return }
        await establish(ep: ep, token: token)
    }

    func connect(rawAddress: String, code: String) async {
        guard !busy else { return }
        busy = true
        lastError = nil
        defer { busy = false }

        guard var ep = ServerEndpoint.parse(rawAddress) else {
            lastError = StashError.badAddress.errorDescription
            return
        }
        // 先探测：地址错/端口错/不是 Stash 都在这一步暴露，不必等配对失败
        do {
            let info = try await APIClient.probe(ep)
            guard info.app == "stash" else {
                lastError = "这个地址不是 Stash（返回的不是素材库服务）"
                return
            }
            if let n = info.name { libraryName = n }
            writeAllowed = info.write ?? false
            if ep.port == 0 { ep.port = 5273 }
        } catch {
            lastError = "连不上 \(ep.display)，检查手机和电脑是否在同一网络"
            return
        }

        do {
            let info = try await APIClient.pair(ep, code: code)
            guard let token = info.token else {
                lastError = "配对失败"
                return
            }
            Keychain.set(token, for: tokenKey)
            await establish(ep: ep, token: token)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func establish(ep: ServerEndpoint, token: String) async {
        let c = APIClient(endpoint: ep, token: token)
        do {
            let info = try await APIClient.probe(ep)
            guard info.app == "stash" else {
                lastError = "这个地址不是 Stash"
                return
            }
            client = c
            endpoint = ep
            libraryName = info.name
            writeAllowed = info.write ?? false
            isConnected = true
            lastError = nil
            epoch += 1
            remember(ep)
        } catch {
            client = nil
            isConnected = false
            endpoint = ep
            lastError = "连不上 \(ep.display)"
        }
    }

    func disconnect(forgetToken: Bool = false) {
        client = nil
        isConnected = false
        epoch += 1
        if forgetToken {
            Keychain.delete(tokenKey)
            UserDefaults.standard.removeObject(forKey: lastKey)
            endpoint = nil
        }
    }

    private func remember(_ ep: ServerEndpoint) {
        UserDefaults.standard.set(ep.display, forKey: lastKey)
        var list = recent.filter { $0.id != ep.id }
        list.insert(ep, at: 0)
        recent = Array(list.prefix(5))
        Self.saveRecent(recent, recentKey)
    }

    private static func loadRecent(_ key: String) -> [ServerEndpoint] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([ServerEndpoint].self, from: data) else { return [] }
        return list
    }

    private static func saveRecent(_ list: [ServerEndpoint], _ key: String) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

// MARK: - 素材列表

@MainActor
@Observable
final class LibraryStore {
    private(set) var items: [Asset] = []
    private(set) var total = 0
    private(set) var loading = false
    private(set) var loadingMore = false
    private(set) var error: String?
    private(set) var tags: [Tag] = []
    private(set) var folders: [Folder] = []

    var query = ""
    var folderPath: String?
    var tagId: Int?
    var typeFilter: String?
    var sort = "-imported_at"

    private var offset = 0
    private var api: APIClient?
    /// 竞态防护：搜索时用户会连打几个字，晚发出的请求可能先回来。
    /// 每次 load 自增，回调里对不上就丢弃 —— 否则列表会「跳回上一个关键词的结果」。
    private var loadSeq = 0

    var hasMore: Bool { items.count < total }

    func attach(_ client: APIClient?) {
        api = client
    }

    func reset() {
        items = []
        total = 0
        offset = 0
        error = nil
        loadSeq += 1
    }

    func reload() async {
        guard let api else { return }
        loadSeq += 1
        let seq = loadSeq
        loading = true
        error = nil
        defer { if seq == loadSeq { loading = false } }

        do {
            let page = try await api.assets(
                query: query,
                folder: folderPath,
                tagId: tagId,
                type: typeFilter,
                sort: sort,
                limit: 60,
                offset: 0
            )
            guard seq == loadSeq else { return }
            items = page.items
            total = page.total
            offset = page.items.count
        } catch {
            guard seq == loadSeq else { return }
            self.error = error.localizedDescription
        }
    }

    func loadMoreIfNeeded(current: Asset) async {
        guard let api, !loadingMore, hasMore else { return }
        guard items.last?.id == current.id else { return }

        loadSeq += 1
        let seq = loadSeq
        loadingMore = true
        defer { if seq == loadSeq { loadingMore = false } }

        do {
            let page = try await api.assets(
                query: query,
                folder: folderPath,
                tagId: tagId,
                type: typeFilter,
                sort: sort,
                limit: 60,
                offset: offset
            )
            guard seq == loadSeq else { return }
            // 去重：SSE/上传刷新与分页可能拿到同一条，重复 id 会让 SwiftUI 列表错位
            let known = Set(items.map(\.id))
            items.append(contentsOf: page.items.filter { !known.contains($0.id) })
            total = page.total
            offset += page.items.count
        } catch {
            guard seq == loadSeq else { return }
            self.error = error.localizedDescription
        }
    }

    func loadFacets() async {
        guard let api else { return }
        // 两个都失败不该互相拖累，各自 try?
        if let f = try? await api.folders() { folders = f.filter { $0.count > 0 } }
        if let t = try? await api.tags() { tags = t.filter { $0.c > 0 } }
    }

    func applyFilters() async {
        await reload()
    }
}
