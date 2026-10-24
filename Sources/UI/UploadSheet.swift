import SwiftUI

/// 传输列表：手机的「收件箱回执」。
/// 上传是异步的，用户点完「+」就该能退出选择器继续干别的，
/// 所以需要一个地方说明「刚才那 12 个文件到底怎么样了」。
struct UploadSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var queue: UploadQueue { model.uploads }

    var body: some View {
        NavigationStack {
            Group {
                if queue.items.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .background(Theme.bg)
            .navigationTitle("传输")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("清理已完成") { queue.clearFinished() }
                        .disabled(queue.items.allSatisfy { $0.status == .queued || $0.status == .uploading || $0.status == .preparing })
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var list: some View {
        List(queue.items) { item in
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    statusIcon(item.status)
                    Text(item.name)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.text1)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(sizeLine(item))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.text3)
                }
                if item.status == .uploading || item.status == .preparing {
                    ProgressView(value: item.fraction)
                        .tint(Theme.accent)
                }
                if let msg = item.message {
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundStyle(item.status == .failed ? Theme.danger : Theme.text3)
                }
            }
            .padding(.vertical, 4)
            .listRowBackground(Theme.panel)
        }
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.up.circle")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Theme.text3)
            Text("还没有传输记录")
                .font(.system(size: 13))
                .foregroundStyle(Theme.text3)
            Text("在素材页点右上角「+」，从相册选照片或视频")
                .font(.system(size: 12))
                .foregroundStyle(Theme.text3.opacity(0.8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    @ViewBuilder
    private func statusIcon(_ s: UploadQueue.Status) -> some View {
        switch s {
        case .queued:
            Image(systemName: "clock").foregroundStyle(Theme.text3)
        case .preparing:
            ProgressView().controlSize(.mini)
        case .uploading:
            Image(systemName: "arrow.up.circle.fill").foregroundStyle(Theme.accent)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
        case .deduped:
            Image(systemName: "equal.circle.fill").foregroundStyle(Theme.text2)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.danger)
        }
    }

    private func sizeLine(_ item: UploadQueue.Item) -> String {
        switch item.status {
        case .uploading, .preparing:
            return "\(ByteCountFormatter.string(fromByteCount: item.sent, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))"
        default:
            return ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
        }
    }
}
