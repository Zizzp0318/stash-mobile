import SwiftUI

/// 连接页。三件事：填地址、填配对码、连上。
/// 刻意不做「自动发现」：Bonjour 要 `NSBonjourServices` + 本地网络权限，
/// 而桌面端目前没广播 mDNS。手输一次地址后被记住，日常几乎不会再进来。
struct ConnectView: View {
    @Environment(AppModel.self) private var model
    @State private var address = ""
    @State private var code = ""
    @State private var showHelp = false

    private var busy: Bool { model.connection.busy }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                VStack(alignment: .leading, spacing: 8) {
                    label("电脑地址")
                    TextField("192.168.1.200:5273", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.system(size: 16, design: .monospaced))
                        .padding(12)
                        .background(Theme.raised)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Theme.border, lineWidth: 0.5)
                        )
                }

                VStack(alignment: .leading, spacing: 8) {
                    label("配对码")
                    TextField("6 位数字", text: $code)
                        .keyboardType(.numberPad)
                        .font(.system(size: 20, weight: .medium, design: .monospaced))
                        .tracking(6)
                        .padding(12)
                        .background(Theme.raised)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Theme.border, lineWidth: 0.5)
                        )
                }

                if let err = model.connection.lastError {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.danger)
                        Text(err)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Button(action: submit) {
                    HStack {
                        if busy { ProgressView().controlSize(.small).tint(Theme.bg) }
                        Text(busy ? "连接中…" : "连接并配对")
                            .font(.system(size: 16, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Theme.accent)
                    .foregroundStyle(Theme.bg)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .disabled(busy || code.count < 6 || address.isEmpty)
                .opacity(busy || code.count < 6 || address.isEmpty ? 0.45 : 1)

                if !model.connection.recent.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        label("最近连接")
                        ForEach(model.connection.recent) { ep in
                            Button {
                                address = ep.display
                            } label: {
                                HStack {
                                    Text(ep.display)
                                        .font(.system(size: 14, design: .monospaced))
                                        .foregroundStyle(Theme.text1)
                                    Spacer()
                                    if ep.host.hasPrefix("100.") {
                                        Text("Tailscale")
                                            .font(.system(size: 11))
                                            .foregroundStyle(Theme.accent)
                                    }
                                }
                                .padding(12)
                                .background(Theme.panel)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(Theme.border, lineWidth: 0.5)
                                )
                            }
                        }
                    }
                }

                helpBox
                Spacer(minLength: 20)
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)
        }
        .background(Theme.bg)
        .onAppear {
            if address.isEmpty { address = model.connection.endpoint?.display ?? "" }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("连接电脑")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Theme.text1)
            Text("打开电脑端 Stash · 设置 · 手机访问，把地址和配对码填进来")
                .font(.system(size: 13))
                .foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var helpBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showHelp.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                    Text("找不到地址？")
                    Image(systemName: showHelp ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11))
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.text2)
            }
            if showHelp {
                VStack(alignment: .leading, spacing: 8) {
                    bullet("手机和电脑连同一个 Wi-Fi，填电脑显示的第一个地址（192.168.x.x）")
                    bullet("不在家时：电脑和手机各装一个 Tailscale 并登录同一账号，填 100.x 的地址")
                    bullet("配对码是 6 位数字，每次重新生成 token 才会变")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.border, lineWidth: 0.5)
        )
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("·").foregroundStyle(Theme.text3)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.text3)
    }

    private func submit() {
        Task {
            await model.connection.connect(rawAddress: address, code: code)
            model.bind()
        }
    }
}
