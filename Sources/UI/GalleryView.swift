import SwiftUI

struct GalleryView: View {
    @Environment(AppModel.self) private var model
    @State private var showPicker = false
    @State private var showSettings = false
    @State private var showUploads = false
    @State private var selected: Asset?

    private var lib: LibraryStore { model.library }
    private var connection: ConnectionStore { model.connection }

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    chipsRow
                    grid
                    footer
                }
                .padding(.bottom, 24)
            }
            .background(Theme.bg)
            .navigationTitle(connection.libraryName ?? "Stash")
            .navigationBarTitleDisplayMode(.large)
            .searchable(
                text: Binding(get: { lib.query }, set: { lib.query = $0 }),
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "搜索文件名"
            )
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showPicker = true } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 20))
                    }
                }
            }
            .refreshable { await lib.reload() }
            .overlay(alignment: .bottom) { uploadBanner }
        }
        // 连接换了/首次连上 → 重拉。用 epoch 而不是 isConnected：
        // 重连同一台机器时布尔量不变，但数据必须刷新
        .task(id: connection.epoch) {
            // 先 bind 再拉：bind 把 client 交给 library，顺序颠倒的话首屏会空一次
            model.bind()
            lib.reset()
            await lib.loadFacets()
            await lib.reload()
        }
        // 搜索防抖：task(id:) 在 query 变化时会取消上一个任务，天然就是 debounce
        .task(id: lib.query) {
            try? await Task.sleep(nanoseconds: 320_000_000)
            guard !Task.isCancelled else { return }
            await lib.reload()
        }
        .sheet(isPresented: $showPicker) {
            PhotoPicker(
                onPicked: { files in
                    model.uploads.enqueue(files)
                    // 上传完让列表自己长出新素材：等服务端 commit 后再刷
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        await model.library.reload()
                    }
                },
                onDismiss: { showPicker = false }
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showUploads) { UploadSheet() }
        .fullScreenCover(item: $selected) { asset in
            ViewerView(assets: lib.items, startAt: asset)
        }
    }

    // MARK: - 筛选

    private var chipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("全部", active: lib.typeFilter == nil && lib.tagId == nil) {
                    lib.typeFilter = nil
                    lib.tagId = nil
                    Task { await lib.applyFilters() }
                }
                chip("图片", active: lib.typeFilter == "image") {
                    lib.typeFilter = lib.typeFilter == "image" ? nil : "image"
                    Task { await lib.applyFilters() }
                }
                chip("视频", active: lib.typeFilter == "video") {
                    lib.typeFilter = lib.typeFilter == "video" ? nil : "video"
                    Task { await lib.applyFilters() }
                }
                if !lib.tags.isEmpty {
                    Rectangle()
                        .fill(Theme.border)
                        .frame(width: 1, height: 18)
                        .padding(.horizontal, 2)
                    ForEach(lib.tags) { tag in
                        chip("\(tag.name) \(tag.c)", active: lib.tagId == tag.id) {
                            lib.tagId = lib.tagId == tag.id ? nil : tag.id
                            Task { await lib.applyFilters() }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func chip(_ text: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(active ? Theme.text1 : Theme.text2)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(active ? Theme.accent.opacity(0.16) : Theme.raised)
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(active ? Theme.accent : Theme.border, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 网格

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(lib.items) { asset in
                AssetCell(asset: asset, client: connection.client)
                    .onTapGesture { selected = asset }
                    .task { await lib.loadMoreIfNeeded(current: asset) }
            }
        }
        .padding(.horizontal, 12)
        .overlay {
            if lib.items.isEmpty {
                if lib.loading {
                    ProgressView().tint(Theme.text3).padding(.top, 60)
                } else {
                    emptyState
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: lib.query.isEmpty ? "photo.on.rectangle.angled" : "magnifyingglass")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.text3)
            Text(lib.error ?? (lib.query.isEmpty ? "这个库里还没有素材" : "没有匹配的素材"))
                .font(.system(size: 13))
                .foregroundStyle(Theme.text3)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
        }
        .padding(.top, 60)
    }

    private var footer: some View {
        HStack {
            Spacer()
            if lib.loadingMore {
                ProgressView().controlSize(.small).tint(Theme.text3)
            } else if !lib.items.isEmpty {
                Text(lib.hasMore ? "\(lib.items.count) / \(lib.total)" : "共 \(lib.total) 个素材")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
            }
            Spacer()
        }
        .padding(.top, 10)
    }

    // MARK: - 上传进度

    @ViewBuilder
    private var uploadBanner: some View {
        if let cur = model.uploads.current {
            Button { showUploads = true } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(cur.status == .preparing ? "处理中" : "正在存入电脑")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.text1)
                        Text(cur.name)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text("\(Int(cur.fraction * 100))%")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.text2)
                    }
                    ProgressView(value: cur.fraction)
                        .tint(Theme.accent)
                }
                .padding(12)
                .background(.ultraThinMaterial)
                .background(Theme.raised.opacity(0.9))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Theme.border, lineWidth: 0.5)
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
            .buttonStyle(.plain)
        }
    }
}

/// 网格单元。统一正方形：瀑布流要自己做 layout，收益不抵复杂度，
/// 而正方形格子滚动时不会因为高度不一而抖动。
struct AssetCell: View {
    let asset: Asset
    let client: APIClient?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let client, let hash = asset.hash {
                    CachedThumb(
                        url: client.thumbURL(hash: hash, size: "grid"),
                        cacheKey: "\(hash)/grid",
                        fallbackSymbol: asset.type.symbol
                    )
                } else {
                    ZStack {
                        Color(white: 0.09)
                        Image(systemName: asset.type.symbol)
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(Color(white: 0.42))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if asset.type == .video, !asset.durationText.isEmpty {
                    Text(asset.durationText)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.55))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .padding(6)
                }
            }
            .overlay(alignment: .bottomLeading) {
                // 文件名做成小药丸而不是整条渐变：渐变会溢出圆角，且把缩略图压掉一截
                Text(asset.name)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .padding(6)
                    .padding(.trailing, asset.type == .video ? 40 : 0)
            }
    }
}
