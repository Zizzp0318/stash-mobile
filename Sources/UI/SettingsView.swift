import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var cacheSize: Int64 = 0
    @State private var showFolderPicker = false
    @State private var confirmForget = false

    private var connection: ConnectionStore { model.connection }

    var body: some View {
        NavigationStack {
            List {
                Section("服务器") {
                    row("地址", connection.endpoint?.display ?? "—")
                    row("素材库", connection.libraryName ?? "—")
                    row("写入", connection.writeAllowed ? "已开放" : "只读")
                }

                Section {
                    Button {
                        showFolderPicker = true
                    } label: {
                        HStack {
                            Text("上传目标目录")
                                .foregroundStyle(Theme.text1)
                            Spacer()
                            Text(currentFolderLabel)
                                .foregroundStyle(Theme.text3)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.text3)
                        }
                    }
                } header: {
                    Text("上传")
                } footer: {
                    Text("不指定时由电脑端收进「手机导入 / 年-月」。内容相同的文件会被自动跳过，不会在库里存两份。")
                }

                Section {
                    HStack {
                        Text("缩略图缓存")
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file))
                            .foregroundStyle(Theme.text3)
                    }
                    Button("清理缓存", role: .destructive) {
                        Task {
                            await ThumbCache.shared.clearDisk()
                            cacheSize = await ThumbCache.shared.diskUsage()
                        }
                    }
                } header: {
                    Text("缓存")
                }

                Section {
                    Button("断开连接") {
                        connection.disconnect()
                        dismiss()
                    }
                    Button("忘记这台电脑", role: .destructive) {
                        confirmForget = true
                    }
                } footer: {
                    Text("「忘记」会同时清除设备里保存的配对凭据，下次需要重新输入 6 位配对码。")
                }

                Section {
                    row("版本", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                    row("接口", "Stash API v2")
                } header: {
                    Text("关于")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task {
                cacheSize = await ThumbCache.shared.diskUsage()
                await model.library.loadFacets()
            }
            .sheet(isPresented: $showFolderPicker) {
                FolderPicker(
                    folders: model.library.folders,
                    selection: Binding(
                        get: { model.uploads.folderId },
                        set: { model.uploads.folderId = $0 }
                    )
                )
            }
            .alert("忘记这台电脑？", isPresented: $confirmForget) {
                Button("取消", role: .cancel) {}
                Button("忘记", role: .destructive) {
                    connection.disconnect(forgetToken: true)
                    dismiss()
                }
            } message: {
                Text("配对凭据会被删除，之后要重新输入配对码才能连接。")
            }
        }
        .preferredColorScheme(.dark)
    }

    private var currentFolderLabel: String {
        guard let id = model.uploads.folderId,
              let f = model.library.folders.first(where: { $0.id == id }) else {
            return "自动（手机导入）"
        }
        return f.path
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundStyle(Theme.text1)
            Spacer()
            Text(v)
                .foregroundStyle(Theme.text3)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

struct FolderPicker: View {
    let folders: [Folder]
    @Binding var selection: Int?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Button {
                    selection = nil
                    dismiss()
                } label: {
                    HStack {
                        Text("自动（手机导入 / 年-月）")
                        Spacer()
                        if selection == nil {
                            Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                        }
                    }
                }
                ForEach(folders) { f in
                    Button {
                        selection = f.id
                        dismiss()
                    } label: {
                        HStack {
                            Text(f.path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text("\(f.count)")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.text3)
                            if selection == f.id {
                                Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                            }
                        }
                    }
                }
            }
            .navigationTitle("上传到")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
