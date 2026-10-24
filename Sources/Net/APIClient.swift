import Foundation

/// 电脑端地址。只支持 IPv4 / 主机名 —— Tailscale 的 100.x 也是 IPv4，够用。
struct ServerEndpoint: Codable, Hashable, Identifiable {
    var host: String
    var port: Int

    var id: String { "\(host):\(port)" }
    var display: String { "\(host):\(port)" }
    var baseURL: URL { URL(string: "http://\(host):\(port)")! }

    /// 用户可能输入 `192.168.1.200:5273`、`http://192.168.1.200:5273/`，也可能只输入 IP
    static func parse(_ raw: String) -> ServerEndpoint? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("https://") { s = String(s.dropFirst(8)) }
        else if s.lowercased().hasPrefix("http://") { s = String(s.dropFirst(7)) }
        while s.hasSuffix("/") { s.removeLast() }
        guard !s.isEmpty else { return nil }

        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2, let p = Int(parts[1]), p > 0, p < 65536 {
            return ServerEndpoint(host: String(parts[0]), port: p)
        }
        if parts.count == 1, !s.contains(":") {
            return ServerEndpoint(host: s, port: 5273)
        }
        return nil
    }
}

/// 和服务端 `remote.ts` 对话。
///
/// 鉴权方式刻意分成两套：
///   · API 请求 → `X-Stash-Token` 请求头（`httpAdditionalHeaders` 一次性设好）
///   · 媒体 URL → `?t=`（`<img>` / `AVPlayer` 拿不到自定义头，只能走查询串）
/// 服务端两套都认（`authed()` + `uploadRoute()`），这里跟着它的口径走，不要自创。
final class APIClient {
    let endpoint: ServerEndpoint
    let token: String
    private let session: URLSession
    private let decoder = JSONDecoder()

    init(endpoint: ServerEndpoint, token: String) {
        self.endpoint = endpoint
        self.token = token
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 900
        c.waitsForConnectivity = true
        c.httpAdditionalHeaders = ["X-Stash-Token": token]
        self.session = URLSession(configuration: c)
    }

    // MARK: - URL

    private func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var comps = URLComponents(
            url: endpoint.baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        if !query.isEmpty { comps.queryItems = query }
        return comps.url ?? endpoint.baseURL
    }

    /// 缩略图 URL（带 `?t=`，给异步图片加载器用）
    func thumbURL(hash: String, size: String = "grid") -> URL {
        url("api/thumb/\(hash)/\(size).webp", query: [URLQueryItem(name: "t", value: token)])
    }

    /// 原图 / 视频 URL。`download: true` 时服务端回 attachment + 原名（中文不乱码）
    func mediaURL(id: Int, download: Bool = false) -> URL {
        var q = [URLQueryItem(name: "t", value: token)]
        if download { q.append(URLQueryItem(name: "dl", value: "1")) }
        return url("api/media/\(id)", query: q)
    }

    // MARK: - 通用请求

    private func send<T: Decodable>(_ req: URLRequest, as type: T.Type) async throws -> T {
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: req)
        } catch {
            throw StashError.offline
        }
        let (data, resp) = result
        guard let http = resp as? HTTPURLResponse else { throw StashError.server("无响应") }
        if http.statusCode == 401 { throw StashError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? decoder.decode(ErrorBody.self, from: data))?.error
            throw StashError.server(msg ?? "HTTP \(http.statusCode)")
        }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw StashError.server("返回数据无法解析")
        }
    }

    private func jsonRequest(_ path: String, method: String, body: Any?) -> URLRequest {
        var req = URLRequest(url: url(path))
        req.httpMethod = method
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    // MARK: - 连接与配对

    /// 探测（不需要 token）。地址能连上但不是 Stash 时返回的 app 字段对不上。
    static func probe(_ ep: ServerEndpoint) async throws -> PingInfo {
        var req = URLRequest(url: ep.baseURL.appendingPathComponent("api/ping"))
        req.timeoutInterval = 6
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 6
        cfg.waitsForConnectivity = false   // 探测要快速失败，别挂着转圈
        // 必须持有这个局部变量：直接写 `URLSession(...).data(...)` 会让 session 在 await 期间被释放
        let session = URLSession(configuration: cfg)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw StashError.http((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(PingInfo.self, from: data)
    }

    /// 6 位配对码换 token
    static func pair(_ ep: ServerEndpoint, code: String) async throws -> PairInfo {
        var req = URLRequest(url: ep.baseURL.appendingPathComponent("api/pair"))
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["code": code])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw StashError.server("无响应") }
        if http.statusCode == 403 { throw StashError.server("配对码不对") }
        guard http.statusCode == 200 else { throw StashError.http(http.statusCode) }
        guard let info = try? JSONDecoder().decode(PairInfo.self, from: data), info.ok, let t = info.token else {
            throw StashError.server("配对失败")
        }
        return PairInfo(ok: true, token: t, write: info.write)
    }

    // MARK: - 读

    func assets(
        query: String = "",
        folder: String? = nil,
        tagId: Int? = nil,
        type: String? = nil,
        sort: String = "-imported_at",
        limit: Int = 60,
        offset: Int = 0
    ) async throws -> AssetPage {
        var q: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "offset", value: "\(offset)"),
            URLQueryItem(name: "sort", value: sort)
        ]
        if !query.isEmpty { q.append(URLQueryItem(name: "q", value: query)) }
        if let folder, !folder.isEmpty { q.append(URLQueryItem(name: "folder", value: folder)) }
        if let tagId, tagId > 0 { q.append(URLQueryItem(name: "tag", value: "\(tagId)")) }
        if let type, !type.isEmpty { q.append(URLQueryItem(name: "type", value: type)) }
        var req = URLRequest(url: url("api/assets", query: q))
        req.timeoutInterval = 20
        return try await send(req, as: AssetPage.self)
    }

    func folders() async throws -> [Folder] {
        try await send(URLRequest(url: url("api/folders")), as: ListResponse<Folder>.self).items
    }

    func tags() async throws -> [Tag] {
        try await send(URLRequest(url: url("api/tags")), as: ListResponse<Tag>.self).items
    }

    // MARK: - 上传（唯一的写通道）

    func beginUpload(name: String, size: Int64, folderId: Int?) async throws -> UploadBegin {
        var body: [String: Any] = ["name": name, "size": size]
        if let folderId { body["folderId"] = folderId }
        let req = jsonRequest("api/upload/begin", method: "POST", body: body)
        return try await send(req, as: UploadBegin.self)
    }

    /// 追加一段。服务端按 `offset` 定位，**重放同一段是幂等的**；
    /// 若服务端已收到的比客户端以为的多（上次其实成功了但响应丢了），会回 409 + received，
    /// 这里抛 `UploadResync` 让队列校正偏移而不是整份重传。
    func putChunk(uploadId: String, offset: Int64, data: Data) async throws -> Int64 {
        var req = URLRequest(url: url("api/upload/\(uploadId)", query: [URLQueryItem(name: "offset", value: "\(offset)")]))
        req.httpMethod = "PUT"
        req.timeoutInterval = 180
        let result: (Data, URLResponse)
        do {
            result = try await session.upload(for: req, from: data)
        } catch {
            throw StashError.offline
        }
        let (respData, resp) = result
        guard let http = resp as? HTTPURLResponse else { throw StashError.server("无响应") }
        if http.statusCode == 401 { throw StashError.unauthorized }
        if http.statusCode == 409 {
            let ack = try? decoder.decode(ReceivedAck.self, from: respData)
            if let r = ack?.received { throw UploadResync(received: r) }
            throw StashError.server("ERR_INCOMPLETE")
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? decoder.decode(ErrorBody.self, from: respData))?.error
            throw StashError.server(msg ?? "HTTP \(http.statusCode)")
        }
        let ack = try decoder.decode(ReceivedAck.self, from: respData)
        return ack.received ?? (offset + Int64(data.count))
    }

    func commitUpload(uploadId: String) async throws -> UploadCommit {
        let req = jsonRequest("api/upload/\(uploadId)/commit", method: "POST", body: nil)
        return try await send(req, as: UploadCommit.self)
    }

    func abortUpload(uploadId: String) async {
        var req = URLRequest(url: url("api/upload/\(uploadId)"))
        req.httpMethod = "DELETE"
        _ = try? await session.data(for: req)
    }
}

/// 服务端已收到的字节数比客户端以为的多 → 校正偏移继续，不要重传
struct UploadResync: Error {
    let received: Int64
}
