import Foundation
import Observation
import UIKit
import ImageIO
import UniformTypeIdentifiers

/// 从系统相册选择后拿到的**本地副本**（系统给的 URL 是临时的，回调返回即失效）
struct PickedFile {
    let url: URL
    let name: String
}

// MARK: - HEIC 转码

enum Transcoder {
    /// 需要转码的扩展名。桌面端 `importer.EXT_TYPE` 里**根本没有 heic/heif** ——
    /// 因为那份预编译 sharp 的 libheif 不带 HEVC 解码器，HEIC 会「导入成功但永远出不了
    /// 缩略图和预览」，比直接拒收更糟。所以转码这一步是手机端的责任，不是可选项。
    static let needsTranscode: Set<String> = ["heic", "heif"]

    /// 单边最大像素。6000 ≈ 36MP：覆盖绝大多数手机拍照（12MP = 4032），
    /// 只有 48MP 的极少数照片会被缩一点，换来的是不会因为一张图把内存打爆。
    static let maxPixel = 6000

    static func isTranscodable(_ ext: String) -> Bool {
        needsTranscode.contains(ext.lowercased())
    }

    /// HEIC → JPEG。用 `CreateThumbnailWithTransform` 把 EXIF 方向**烤进像素**：
    /// 否则竖着拍的照片在电脑端会是躺倒的（很多转换器栽在这里）。
    static func jpeg(from src: URL, quality: CGFloat = 0.92) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil) else {
            throw TranscodeError.decode
        }
        let props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else {
            throw TranscodeError.decode
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("stash-up-\(UUID().uuidString).jpg")
        guard let out = CGImageDestinationCreateWithURL(
            dest as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw TranscodeError.encode }

        var outProps: [CFString: Any] = props
        outProps[kCGImagePropertyOrientation] = 1
        outProps[kCGImageDestinationLossyCompressionQuality] = quality
        outProps.removeValue(forKey: kCGImagePropertyPixelWidth)
        outProps.removeValue(forKey: kCGImagePropertyPixelHeight)
        CGImageDestinationAddImage(out, cg, outProps as CFDictionary)
        guard CGImageDestinationFinalize(out) else { throw TranscodeError.encode }
        return dest
    }
}

enum TranscodeError: LocalizedError {
    case decode, encode
    var errorDescription: String? {
        switch self {
        case .decode: return "无法解码这张照片（HEIC 可能已损坏）"
        case .encode: return "转码失败"
        }
    }
}

// MARK: - 上传队列

/// 手机 → 电脑。**串行**上传（一次一张）：家庭 Wi-Fi 上并行只会互相抢带宽，
/// 而且串行让「当前这张的进度」在 UI 上永远是真的，不会出现四个进度条一起抖动。
@MainActor
@Observable
final class UploadQueue {
    enum Status: Equatable {
        case queued, preparing, uploading, done, deduped, failed
    }

    struct Item: Identifiable {
        let id = UUID()
        var name: String
        var size: Int64
        var sent: Int64 = 0
        var status: Status = .queued
        var message: String?
        var assetId: Int?

        var fraction: Double {
            guard size > 0 else { return 0 }
            return min(1, Double(sent) / Double(size))
        }
    }

    private(set) var items: [Item] = []
    /// 上传目标目录。nil = 让电脑端收进「手机导入/年-月」
    var folderId: Int?
    private(set) var lastError: String?

    private var api: APIClient?
    private var draining = false
    /// 4 MB 一段：太小则请求数暴涨（1GB 视频 = 256 个请求），太大则一段失败要重传很久
    private let chunkSize = 4 * 1024 * 1024

    var activeCount: Int {
        items.filter { $0.status == .queued || $0.status == .preparing || $0.status == .uploading }.count
    }

    var current: Item? {
        items.first { $0.status == .uploading || $0.status == .preparing }
    }

    func attach(_ client: APIClient?) {
        api = client
    }

    func clearFinished() {
        items.removeAll { $0.status == .done || $0.status == .deduped || $0.status == .failed }
    }

    func enqueue(_ files: [PickedFile]) {
        guard !files.isEmpty else { return }
        lastError = nil
        for f in files {
            items.append(Item(name: f.name, size: fileSize(f.url)))
        }
        // 队列本体和文件绑定在一起：Item 只负责展示，真正的文件另存一张表，
        // 避免把 URL 塞进 View 层的数据结构里（那会让「重试」没法独立于视图存在）
        pendingFiles.append(contentsOf: files)
        startDraining()
    }

    private var pendingFiles: [PickedFile] = []

    private func fileSize(_ url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func startDraining() {
        guard !draining else { return }
        draining = true
        Task { await drain() }
    }

    private func drain() async {
        defer { draining = false }
        // 上传可能几十秒到几分钟，给一段后台宽限期；到期没传完就停下，下次前台继续
        let bg = UIApplication.shared.beginBackgroundTask(withName: "stash-upload")
        defer { if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) } }

        while !pendingFiles.isEmpty {
            let file = pendingFiles.removeFirst()
            guard let itemID = items.first(where: { $0.status == .queued })?.id else { continue }
            await process(itemID: itemID, file: file)
        }
    }

    /// 按 id 定位后再改。
    /// **不要用捕获下来的下标**：`clearFinished()` 会在上传过程中删掉已完成项，下标整体前移，
    /// 拿旧下标记账会把进度写到别人身上，甚至数组越界。
    private func mutate(_ id: UUID, _ body: (inout Item) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        body(&items[i])
    }

    private func process(itemID: UUID, file: PickedFile) async {
        guard let api else {
            mutate(itemID) {
                $0.status = .failed
                $0.message = "未连接电脑"
            }
            return
        }

        var uploaded: URL? = file.url
        var cleanup: URL?
        var name = file.name

        do {
            mutate(itemID) { $0.status = .preparing }
            let ext = (name as NSString).pathExtension.lowercased()
            if Transcoder.isTranscodable(ext) {
                let jpg = try Transcoder.jpeg(from: file.url)
                cleanup = jpg
                uploaded = jpg
                name = (name as NSString).deletingPathExtension + ".jpg"
                let sz = fileSize(jpg)
                mutate(itemID) {
                    $0.name = name
                    $0.size = sz
                }
            }

            guard let src = uploaded else { throw StashError.server("文件不可读") }
            let size = fileSize(src)
            guard size > 0 else { throw StashError.server("文件是空的") }

            mutate(itemID) { $0.status = .uploading }
            let begin = try await api.beginUpload(name: name, size: size, folderId: folderId)
            var offset = begin.offset
            mutate(itemID) { $0.sent = offset }

            while offset < size {
                let want = Int(min(Int64(chunkSize), size - offset))
                let chunk = try readChunk(src, offset: offset, length: want)
                if chunk.isEmpty { break }

                var attempt = 0
                while true {
                    do {
                        let recv = try await api.putChunk(uploadId: begin.uploadId, offset: offset, data: chunk)
                        guard recv > offset else {
                            // 回了 200 但进度没前进 → 再循环就是死循环，直接判失败
                            throw StashError.server("上传进度异常")
                        }
                        offset = recv
                        mutate(itemID) { $0.sent = offset }
                        break
                    } catch let resync as UploadResync {
                        // 服务端已经收到的比我们以为的多（上次的成功响应丢了）→ 对齐继续
                        offset = resync.received
                        mutate(itemID) { $0.sent = offset }
                        break
                    } catch {
                        attempt += 1
                        if attempt >= 3 {
                            await api.abortUpload(uploadId: begin.uploadId)
                            throw error
                        }
                        try? await Task.sleep(nanoseconds: UInt64(attempt) * 900_000_000)
                    }
                }
            }

            let commit = try await api.commitUpload(uploadId: begin.uploadId)
            mutate(itemID) { item in
                item.assetId = commit.assetId
                if commit.deduped == true {
                    item.status = .deduped
                    item.message = "库里已有，已跳过"
                } else {
                    item.status = .done
                    item.sent = item.size
                    item.message = commit.renamed == true ? "已存入（重名已自动改名）" : "已存入"
                }
            }
        } catch {
            mutate(itemID) {
                $0.status = .failed
                $0.message = error.localizedDescription
            }
            lastError = error.localizedDescription
        }

        // 临时文件（Picker 拷贝出来的 + 转码产物）都清掉
        try? FileManager.default.removeItem(at: file.url)
        if let cleanup { try? FileManager.default.removeItem(at: cleanup) }
    }

    private func readChunk(_ url: URL, offset: Int64, length: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        return (try handle.read(upToCount: length)) ?? Data()
    }
}
