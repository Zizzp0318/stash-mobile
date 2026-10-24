import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// 系统相册选择器。
///
/// 用 `PHPickerViewController` 而不是 `PHAsset` 全量读取，是因为它**不需要相册权限**：
/// 选择器在独立进程里跑，只把用户挑中的那几张递给我们。少一个权限弹窗，
/// 也少一份「App 能扫你整个相册」的隐私负担。
struct PhotoPicker: UIViewControllerRepresentable {
    var onPicked: ([PickedFile]) -> Void
    /// 必须显式回调：UIKit 里 `picker.dismiss()` 不会把 SwiftUI 的 `@State showPicker` 置回 false，
    /// 结果就是「选完一次之后再点 + 没反应」——因为 sheet 的绑定还停在 true。
    var onDismiss: () -> Void = {}

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var cfg = PHPickerConfiguration()
        cfg.filter = .any(of: [.images, .videos])
        cfg.selectionLimit = 0                 // 0 = 不限张数
        cfg.preferredAssetRepresentationMode = .current  // 别让系统替我们转码，HEIC 交给我们自己判
        let vc = PHPickerViewController(configuration: cfg)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPicked: onPicked, onDismiss: onDismiss)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onPicked: ([PickedFile]) -> Void
        private let onDismiss: () -> Void

        init(onPicked: @escaping ([PickedFile]) -> Void, onDismiss: @escaping () -> Void) {
            self.onPicked = onPicked
            self.onDismiss = onDismiss
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            onDismiss()
            guard !results.isEmpty else { return }

            let group = DispatchGroup()
            let lock = NSLock()
            var slots = [PickedFile?](repeating: nil, count: results.count)

            for (i, result) in results.enumerated() {
                let provider = result.itemProvider
                let typeID: String
                if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                    typeID = UTType.movie.identifier
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    typeID = UTType.image.identifier
                } else {
                    continue
                }

                group.enter()
                provider.loadFileRepresentation(forTypeIdentifier: typeID) { url, _ in
                    defer { group.leave() }
                    // ⚠️ 这个 url 在闭包返回后立刻失效，必须**当场**拷走
                    guard let url else { return }
                    let rawExt = url.pathExtension.isEmpty
                        ? (typeID == UTType.movie.identifier ? "mov" : "jpg")
                        : url.pathExtension
                    // suggestedName 有时带扩展名、有时不带，统一剥掉再拼，避免出现 IMG_1.HEIC.jpg
                    let base = ((provider.suggestedName ?? "手机素材-\(i + 1)") as NSString).deletingPathExtension
                    let dest = FileManager.default.temporaryDirectory
                        .appendingPathComponent("stash-pick-\(UUID().uuidString).\(rawExt)")
                    do {
                        try FileManager.default.copyItem(at: url, to: dest)
                        let file = PickedFile(url: dest, name: "\(base).\(rawExt)")
                        lock.lock()
                        slots[i] = file
                        lock.unlock()
                    } catch {
                        // 单个文件拷不出来就跳过，不影响其余选中项
                    }
                }
            }

            group.notify(queue: .main) {
                let files = slots.compactMap { $0 }
                if !files.isEmpty { self.onPicked(files) }
            }
        }
    }
}
