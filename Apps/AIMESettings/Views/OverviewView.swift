import AIMECore
import AIMEPanel
import SwiftUI

struct OverviewView: View {
    @Environment(SettingsModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Binding var selection: Pane?
    @State private var showingImport = false

    var body: some View {
        PaneColumn {
            VStack(alignment: .leading, spacing: 20) {
                hero
                if model.pendingUpdate != nil { UpdateCard() }
                statusGrid
                importCard
                quickLinks
                VersionFooter()
            }
        }
        .task { await model.refreshUpdates() }
    }

    private var hero: some View {
        // Side by side when there is room; the preview drops below the copy otherwise,
        // so the text column is never squeezed into a few characters per line.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 28) {
                heroCopy
                Spacer(minLength: 12)
                heroPreview
            }
            VStack(alignment: .leading, spacing: 20) {
                heroCopy
                heroPreview
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.cardBorder))
    }

    private var heroCopy: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image("BrandLockup")
                .resizable().scaledToFit().frame(width: 240, height: 89)
                .accessibilityLabel("AIME 艾么输入法")
            Text("中文常新，自在表达。")
                .font(.title3.weight(.medium)).foregroundStyle(Theme.secondaryText)
            Text("可视化管理方案、外观与词库")
                .font(.title3).foregroundStyle(Theme.secondaryText)
            HStack(spacing: 8) {
                Tag(text: "librime 1.17", symbol: "cpu")
                Tag(text: model.enabledSchemas.first.map { "主方案 \($0)" } ?? "尚未部署", symbol: "character.book.closed")
            }
        }
        .fixedSize()
    }

    private var heroPreview: some View {
        PanelPreview(theme: model.theme(dark: colorScheme == .dark))
            .fixedSize()
            .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
    }

    private var statusGrid: some View {
        Grid(horizontalSpacing: 14, verticalSpacing: 14) {
            GridRow {
                StatusCard(
                    title: "输入法",
                    value: !model.isInstalled ? "未安装" : model.isInputSourceEnabled ? "已启用" : "已安装",
                    detail: !model.isInstalled ? "运行 scripts/install-dev.sh 或安装 pkg"
                        : model.isInputSourceEnabled ? "按 ⌃空格 切换到艾么输入法即可输入" : "系统设置 › 键盘 › 输入法 中添加艾么输入法",
                    symbol: "keyboard.badge.ellipsis", ok: model.isInstalled && model.isInputSourceEnabled
                )
                StatusCard(
                    title: "部署", value: model.isDeployed ? "已部署" : "等待首次部署",
                    detail: model.hasPendingChanges ? "正在应用更改…" : "配置与输入法一致",
                    symbol: "shippingbox", ok: model.isDeployed && !model.hasPendingChanges
                )
                StatusCard(
                    title: "输入方案", value: "\(model.enabledSchemas.count) 个启用",
                    detail: model.enabledSchemas.prefix(3).joined(separator: " · "),
                    symbol: "character.book.closed", ok: !model.enabledSchemas.isEmpty
                )
            }
        }
    }

    private var importCard: some View {
        HStack(spacing: 16) {
            Image(systemName: "square.and.arrow.down.on.square").font(.title).foregroundStyle(Theme.accentText)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.hasImported ? "重新导入 RIME 配置" : "导入 RIME 配置").font(.headline)
                Text("一键导入鼠须管等 RIME 目录的方案、词库、全拼 / 双拼自定义短语与词频（只读，短语自动合并）。")
                    .font(.callout).foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            Button(model.hasImported ? "重新导入…" : "导入…") { showingImport = true }
                .buttonStyle(.borderedProminent)
                .disabled(model.deployState == .deploying)
        }
        .padding(18)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .sheet(isPresented: $showingImport) { ImportSheet() }
        .task {
            // Screenshot automation: scripts can open the sheet with --import-sheet.
            if ProcessInfo.processInfo.arguments.contains("--import-sheet") {
                try? await Task.sleep(for: .milliseconds(400))
                showingImport = true
            }
        }
    }

    private var quickLinks: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("常用").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                ForEach([Pane.appearance, .schemas, .spelling, .dictionaries, .phrases, .ai]) { pane in
                    Button { selection = pane } label: {
                        HStack(spacing: 10) {
                            Image(systemName: pane.symbol).frame(width: 22).foregroundStyle(Theme.accentText)
                            Text(pane.title).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(14)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct StatusCard: View {
    let title: LocalizedStringKey
    let value: String
    let detail: String
    let symbol: String
    let ok: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: symbol).foregroundStyle(Theme.secondaryText)
                Text(title).font(.subheadline).foregroundStyle(Theme.secondaryText)
                Spacer()
                Circle().fill(ok ? Color.green : Color.orange).frame(width: 8, height: 8)
            }
            Text(value).font(.title3.weight(.semibold))
            Text(detail.isEmpty ? " " : detail).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct Tag: View {
    let text: String
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .lineLimit(1)
            .fixedSize()
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.thinMaterial, in: Capsule())
    }
}

/// Shown on the overview when a newer release is available.
struct UpdateCard: View {
    @Environment(SettingsModel.self) private var model

    var body: some View {
        if let release = model.pendingUpdate {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: "arrow.down.circle.fill").font(.title).foregroundStyle(Theme.accentText)
                VStack(alignment: .leading, spacing: 4) {
                    Text("新版本 \(release.appVersion.description) 可以更新").font(.headline)
                    Text(detail(release)).font(.callout).foregroundStyle(Theme.secondaryText)
                    if let notes = release.notes, !notes.isEmpty {
                        Text(notes).font(.callout).foregroundStyle(Theme.secondaryText).lineLimit(3)
                    }
                    if let progress = model.updateProgress {
                        ProgressView(value: progress).frame(maxWidth: 260)
                    } else if let notice = model.updateNotice {
                        Text(notice).font(.caption).foregroundStyle(Theme.secondaryText)
                    }
                }
                Spacer()
                Button("跳过此版本") { model.skipUpdate() }
                    .disabled(model.updateProgress != nil)
                Button("下载并安装") { Task { await model.installUpdate() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.updateProgress != nil)
            }
            .padding(18)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.accent.opacity(0.45)))
        }
    }

    private func detail(_ release: AppRelease) -> String {
        var parts = ["当前 \(model.currentVersion.description)"]
        if let date = release.date { parts.append("发布于 \(date)") }
        if let size = release.installer?.size { parts.append(String(format: "%.1f MB", Double(size) / 1_000_000)) }
        parts.append("下载后校验 SHA-256 与开发者签名，再交给系统安装器")
        return parts.joined(separator: " · ")
    }
}

/// Version, automatic checking and a manual check, at the bottom of the overview.
struct VersionFooter: View {
    @Environment(SettingsModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Text("艾么输入法 \(model.currentVersion.description)\(model.isDistributionBuild ? "" : " · 开发版")")
                .font(.caption).foregroundStyle(Theme.secondaryText)
            Spacer()
            if let notice = model.updateNotice, model.pendingUpdate == nil {
                Text(notice).font(.caption).foregroundStyle(Theme.secondaryText)
            }
            Toggle("自动检查更新", isOn: Binding(get: { model.updateState.autoCheck }, set: { model.setAutoUpdate($0) }))
                .toggleStyle(.checkbox).font(.caption)
                .help("每天请求一次 get.zool.app 上公开的版本清单，不发送任何输入内容")
            Button {
                Task { await model.checkForUpdates(userInitiated: true) }
            } label: {
                if model.updateChecking { ProgressView().controlSize(.small) } else { Text("检查更新") }
            }
            .controlSize(.small)
            .disabled(model.updateChecking)
        }
        .padding(.top, 4)
    }
}
