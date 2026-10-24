import SwiftUI
import AVKit
import Photos
import ImageIO

struct ViewerView: View {
    let assets: [Asset]
    @State private var index: Int
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var zoomed = false
    @State private var saving = false
    @State private var showInfo = false
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    init(assets: [Asset], startAt asset: Asset) {
        self.assets = assets
        _index = State(initialValue: assets.firstIndex(where: { $0.id == asset.id }) ?? 0)
    }

    private var current: Asset { assets[min(max(index, 0), assets.count - 1)] }
    private var client: APIClient? { model.connection.client }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
            chrome
            if let toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text1)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Theme.raised.opacity(0.95))
                        .clipShape(Capsule())
                        .padding(.bottom, 110)
                }
                .transition(.opacity)
            }
        }
        .statusBarHidden()
        .task(id: current.id) { await load() }
        .onDisappear {
            player?.pause()
            toastTask?.cancel()
        }
        .sheet(isPresented: $showInfo) { infoSheet }
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        switch current.type {
        case .video:
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else {
                loadingView
            }
        case .image:
            if let image {
                ZoomableImage(image: image) { z in zoomed = z }
                    .ignoresSafeArea()
            } else {
                loadingView
            }
        default:
            VStack(spacing: 8) {
                Image(systemName: current.type.symbol)
                    .font(.system(size: 34, weight: .light))
                Text("这类素材不支持在线预览，点下方「保存」下载到相册")
                    .font(.system(size: 13))
            }
            .foregroundStyle(Theme.text3)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 10) {
            ProgressView().tint(Theme.text3)
            Text(current.sizeText)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text3)
        }
    }

    // MARK: - 顶栏 / 底栏

    private var chrome: some View {
        VStack {
            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.text1)
                        .frame(width: 34, height: 34)
                        .background(Theme.raised.opacity(0.85))
                        .clipShape(Circle())
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(current.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text1)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(current.dimsText) · \(current.sizeText)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text3)
                }
                Spacer()
                Text("\(index + 1) / \(assets.count)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.text2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Theme.raised.opacity(0.85))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)

            Spacer()

            HStack(spacing: 10) {
                chromeButton("保存到相册", systemImage: saving ? "hourglass" : "square.and.arrow.down", primary: true) {
                    save()
                }
                chromeButton("信息", systemImage: "info.circle") { showInfo = true }
                if assets.count > 1 {
                    chromeButton("上一张", systemImage: "chevron.left") { prev() }
                    chromeButton("下一张", systemImage: "chevron.right") { next() }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 18)
        }
    }

    private func chromeButton(_ title: String, systemImage: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 13))
                Text(title).font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(primary ? Theme.bg : Theme.text1)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(primary ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.raised.opacity(0.9)))
            .clipShape(Capsule())
        }
        .disabled(primary && saving)
    }

    // MARK: - 信息

    private var infoSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("素材信息").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("完成") { showInfo = false }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            ScrollView {
                VStack(spacing: 0) {
                    row("文件名", current.name)
                    row("类型", current.type.label)
                    if !current.dimsText.isEmpty { row("尺寸", current.dimsText) }
                    if !current.durationText.isEmpty { row("时长", current.durationText) }
                    row("大小", current.sizeText)
                    row("入库时间", current.date.formatted(date: .numeric, time: .shortened))
                    if let r = current.rating, r > 0 { row("评分", String(repeating: "★", count: r)) }
                    if let h = current.hash { row("内容哈希", h) }
                }
                .padding(.horizontal, 20)
            }
        }
        .presentationDetents([.medium])
        .presentationBackground(Theme.panel)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(k)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text3)
                .frame(width: 76, alignment: .leading)
            Text(v)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text1)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 0.5)
        }
    }

    // MARK: - 行为

    private func load() async {
        guard let client else { return }
        player?.pause()
        player = nil
        image = nil
        zoomed = false

        switch current.type {
        case .image:
            let target = current.id
            let img = await ImageLoader.shared.load(url: client.mediaURL(id: target))
            // 翻页时上一张的请求可能晚回来：只有「还是同一张」才落图，
            // 否则会出现「明明翻到了第 5 张，画面却是第 4 张」
            guard !Task.isCancelled, current.id == target else { return }
            image = img
        case .video:
            let p = AVPlayer(url: client.mediaURL(id: current.id))
            player = p
            p.play()
        default:
            break
        }
    }

    private func next() {
        guard index + 1 < assets.count else { return }
        index += 1
    }

    private func prev() {
        guard index > 0 else { return }
        index -= 1
    }

    private func save() {
        guard let client, !saving else { return }
        saving = true
        let a = current
        Task {
            do {
                try await PhotoSaver.save(
                    url: client.mediaURL(id: a.id, download: true),
                    isVideo: a.type == .video,
                    name: a.name
                )
                showToast("已保存到相册")
            } catch {
                showToast(error.localizedDescription)
            }
            saving = false
        }
    }

    private func showToast(_ text: String) {
        withAnimation(.easeOut(duration: 0.15)) { toast = text }
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) { toast = nil }
        }
    }
}

// MARK: - 缩放视图

/// 用 `UIScrollView` 包 `UIImageView`，而不是纯 SwiftUI 手势。
///
/// 原因很实际：SwiftUI 手写「双击以触点为中心放大 + 边界回弹 + 惯性」需要自己算一堆几何，
/// 而 UIScrollView 的 `zoom(to:animated:)` 一行就对了，边界和惯性还是系统级手感。
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    var onZoomChange: (Bool) -> Void = { _ in }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 5
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.delegate = context.coordinator
        scroll.backgroundColor = .black

        let iv = UIImageView(image: image)
        iv.contentMode = .scaleAspectFit
        iv.isUserInteractionEnabled = true
        iv.frame = scroll.bounds
        iv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.addSubview(iv)
        context.coordinator.imageView = iv

        let double = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        double.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(double)

        return scroll
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        if context.coordinator.imageView?.image !== image {
            context.coordinator.imageView?.image = image
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onZoomChange: onZoomChange) }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var imageView: UIImageView?
        private let onZoomChange: (Bool) -> Void

        init(onZoomChange: @escaping (Bool) -> Void) {
            self.onZoomChange = onZoomChange
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            onZoomChange(scrollView.zoomScale > 1.02)
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            if scrollView.zoomScale > 1.02 {
                scrollView.setZoomScale(1, animated: true)
            } else {
                // 以双击点为中心放大到 2.5 倍
                let point = gesture.location(in: imageView)
                let w = scrollView.bounds.width / 2.5
                let h = scrollView.bounds.height / 2.5
                let rect = CGRect(x: point.x - w / 2, y: point.y - h / 2, width: w, height: h)
                scrollView.zoom(to: rect, animated: true)
            }
        }
    }
}

// MARK: - 原图加载

/// 按屏幕尺寸降采样后再解码。
/// 库里可能有 48MP 的图，直接 `UIImage(data:)` 会解出近 200MB 的位图 —— 在手机上就是闪退。
actor ImageLoader {
    static let shared = ImageLoader()

    func load(url: URL, maxPixel: Int = 3000) async -> UIImage? {
        guard let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // 烤进 EXIF 方向，竖拍不会躺倒
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
            return UIImage(cgImage: cg)
        }
        return UIImage(data: data)
    }
}

// MARK: - 保存到相册

enum PhotoSaver {
    static func save(url: URL, isVideo: Bool, name: String) async throws {
        let (tmp, resp) = try await URLSession.shared.download(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw StashError.server("下载失败")
        }

        var ext = (name as NSString).pathExtension.lowercased()
        if ext.isEmpty { ext = isVideo ? "mov" : "jpg" }

        // 相册对扩展名敏感：webp / gif 直接塞进去会被拒，统一先落成 jpg
        let needsConvert = !isVideo && !["jpg", "jpeg", "png", "heic", "heif"].contains(ext)
        var finalURL = tmp

        if needsConvert {
            guard let data = try? Data(contentsOf: tmp),
                  let image = UIImage(data: data),
                  let jpeg = image.jpegData(compressionQuality: 0.95) else {
                throw StashError.server("这张图无法转成相册支持的格式")
            }
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("save-\(UUID().uuidString).jpg")
            try jpeg.write(to: dest)
            finalURL = dest
            ext = "jpg"
        } else {
            // download 给的是无扩展名的临时文件，相册要靠扩展名判断类型
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("save-\(UUID().uuidString).\(ext)")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            finalURL = dest
        }

        try await PHPhotoLibrary.shared().performChanges {
            if isVideo {
                _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: finalURL)
            } else {
                _ = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: finalURL)
            }
        }
        try? FileManager.default.removeItem(at: finalURL)
    }
}
