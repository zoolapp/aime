import SwiftUI

struct AboutView: View {
    @Environment(SettingsModel.self) private var model

    // The build phase stamps UTC into the signed bundle; opening this page never changes it.
    private let buildDate: Date? = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "AIMEBuildDate") as? String else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }()

    var body: some View {
        PaneColumn {
            VStack(alignment: .leading, spacing: 28) {
                brand
                version
                projectLinks
                licenses
                Text("© 2026 ZOOL LLC. 感谢 RIME 与开源社区。")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("关于艾么输入法")
    }

    private var brand: some View {
        VStack(spacing: 12) {
            Image("BrandLockup")
                .resizable()
                .scaledToFit()
                .frame(width: 240, height: 89)
                .accessibilityLabel("AIME 艾么输入法")
            Text("中文常新，自在表达。")
                .font(.title3)
                .foregroundStyle(Theme.text)
            Text("基于 RIME 的开源 macOS 中文输入法。")
                .font(.callout)
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var version: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("版本 \(model.currentVersion.string)")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    if isDevelopmentBuild {
                        Text("开发版")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                    if let build = model.currentVersion.build {
                        GridRow {
                            Text("构建号")
                            Text(build, format: .number.grouping(.never))
                                .monospacedDigit()
                                .textSelection(.enabled)
                                .foregroundStyle(Theme.text)
                        }
                    }
                    GridRow {
                        Text("构建时间")
                        if let buildDate {
                            Text(formattedBuildDate(buildDate))
                                .monospacedDigit()
                                .textSelection(.enabled)
                                .foregroundStyle(Theme.text)
                                .help("按本机时区显示当前版本的构建时间")
                        } else {
                            Text("未记录")
                                .help("此版本未包含构建时间")
                        }
                    }
                }
                .font(.callout)
                .foregroundStyle(Theme.secondaryText)
            }
            .padding(20)
        }
    }

    private func formattedBuildDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter.string(from: date)
    }

    private var isDevelopmentBuild: Bool {
        #if DEBUG
        true
        #else
        !model.isDistributionBuild
        #endif
    }

    private var projectLinks: some View {
        Card {
            projectLink("开源仓库", address: "github.com/zoolapp/aime", destination: "https://github.com/zoolapp/aime") {
                Image("GitHubMark").resizable().scaledToFit()
            }
            Rectangle().fill(Theme.divider).frame(height: 1).padding(.horizontal, 20)
            projectLink("官方网站", address: "aime.zool.app", destination: "https://aime.zool.app") {
                Image(systemName: "globe").font(.title2)
            }
        }
    }

    private func projectLink<Icon: View>(_ title: LocalizedStringKey, address: String, destination: String, @ViewBuilder icon: () -> Icon) -> some View {
        Link(destination: URL(string: destination)!) {
            HStack(spacing: 12) {
                icon()
                    .frame(width: 24, height: 24)
                    .foregroundStyle(Theme.text)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.body.weight(.medium)).foregroundStyle(Theme.text)
                    Text(address).font(.callout).foregroundStyle(Theme.secondaryText)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.accentText)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var licenses: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("开源与许可")
                .font(.headline)
                .foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)
            Text("AIME 原创源码采用 MIT 协议。安装包包含 GPL-3.0 组件，整体按 GPL-3.0 分发；各依赖与词库遵循各自许可。")
                .font(.callout)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 18) {
                Link("MIT 协议", destination: URL(string: "https://github.com/zoolapp/aime/blob/main/LICENSE")!)
                Link("第三方声明", destination: URL(string: "https://github.com/zoolapp/aime/blob/main/THIRD_PARTY_NOTICES.md")!)
            }
            .font(.callout)
            .foregroundStyle(Theme.accentText)
        }
    }
}
