import Foundation
import CoreGraphics

/// 素材类型。服务端是字符串，这里容错解析（将来桌面端加了新类型也不会让整页解码失败）
enum AssetType: String, Codable, Hashable {
    case image, video, audio, text, unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AssetType(rawValue: raw) ?? .unknown
    }

    var label: String {
        switch self {
        case .image: return "图片"
        case .video: return "视频"
        case .audio: return "音频"
        case .text: return "文本"
        case .unknown: return "其他"
        }
    }

    var symbol: String {
        switch self {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .text: return "doc.text"
        case .unknown: return "questionmark.square"
        }
    }
}

struct Asset: Identifiable, Codable, Hashable {
    let id: Int
    let name: String
    let type: AssetType
    let width: Int?
    let height: Int?
    let size: Int64
    let durationMs: Int?
    /// ⚠️ **epoch 毫秒**，不是字符串、不是秒。桌面端 `assets.imported_at` 就是整数毫秒。
    /// 按秒解析会得到 1970 年，卡片排序和日期全都错。
    let importedAt: Int64
    /// 缩略图 hash（20 位 hex）。服务端已过 `isThumbHash` 闸门，非法值为 null
    let hash: String?
    let rating: Int?
    let isFav: Int?
    let palette: String?

    enum CodingKeys: String, CodingKey {
        case id, name, type, width, height, size, hash, rating, palette
        case durationMs = "duration_ms"
        case importedAt = "imported_at"
        case isFav = "is_fav"
    }

    var aspect: CGFloat {
        guard let w = width, let h = height, w > 0, h > 0 else { return 1 }
        return CGFloat(w) / CGFloat(h)
    }

    var date: Date {
        Date(timeIntervalSince1970: TimeInterval(importedAt) / 1000)
    }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var dimsText: String {
        guard let w = width, let h = height else { return "" }
        return "\(w) × \(h)"
    }

    var durationText: String {
        guard let ms = durationMs, ms > 0 else { return "" }
        let s = ms / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct AssetPage: Decodable {
    let total: Int
    let items: [Asset]
}

struct Folder: Identifiable, Codable, Hashable {
    let id: Int
    let path: String
    let name: String
    let depth: Int
    let count: Int
}

struct Tag: Identifiable, Codable, Hashable {
    let id: Int
    let name: String
    let color: String?
    let c: Int
}

struct ListResponse<T: Decodable>: Decodable {
    let items: [T]
}

struct PingInfo: Decodable {
    let app: String
    let api: Int?
    let name: String?
    let write: Bool?
}

struct PairInfo: Decodable {
    let ok: Bool
    let token: String?
    let write: Bool?
}

struct UploadBegin: Decodable {
    let ok: Bool
    let uploadId: String
    let offset: Int64
    let name: String
}

struct ReceivedAck: Decodable {
    let ok: Bool?
    let received: Int64?
    let size: Int64?
}

struct UploadCommit: Decodable {
    let ok: Bool
    let assetId: Int?
    let name: String?
    let deduped: Bool?
    let renamed: Bool?
}

struct ErrorBody: Decodable {
    let ok: Bool?
    let error: String?
}

/// 用户能看懂的失败原因。中文文案集中在这里，别散落到各个调用点。
enum StashError: LocalizedError {
    case badAddress
    case unauthorized
    case uploadDisabled
    case server(String)
    case http(Int)
    case offline

    var errorDescription: String? {
        switch self {
        case .badAddress: return "地址格式不对，例：192.168.1.200:5273"
        case .unauthorized: return "配对已失效，请重新配对"
        case .uploadDisabled: return "电脑端关闭了「允许手机上传」"
        case .server(let m):
            switch m {
            case "ERR_UNSUPPORTED_TYPE": return "电脑端不支持这种格式"
            case "ERR_TOO_LARGE": return "文件太大（上限 8 GB）"
            case "ERR_NO_LIBRARY": return "电脑端还没有打开素材库"
            case "ERR_UPLOAD_DISABLED": return "电脑端关闭了「允许手机上传」"
            case "ERR_INCOMPLETE": return "上传不完整，请重试"
            default: return m
            }
        case .http(let c): return "服务器返回 \(c)"
        case .offline: return "连不上电脑，检查网络或 Tailscale"
        }
    }
}
