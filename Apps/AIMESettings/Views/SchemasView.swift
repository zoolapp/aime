import AIMECore
import SwiftUI

struct SchemasView: View {
    @Environment(SettingsModel.self) private var model

    var body: some View {
        let enabled = model.enabledSchemas
        let available = model.availableSchemas
        let byID = Dictionary(uniqueKeysWithValues: available.map { ($0.id, $0) })
        Form {
            Section { PaneHeader(title: "输入方案", subtitle: "启用与排序输入方案。第一个是默认方案，其余可在方案选单（⌃⇧`）中切换。", symbol: "character.book.closed") }


            Section("已启用") {
                if enabled.isEmpty {
                    Text("尚未启用任何方案").foregroundStyle(.secondary)
                }
                ForEach(Array(enabled.enumerated()), id: \.element) { index, id in
                    SchemaRow(info: byID[id], id: id, isDefault: index == 0) {
                        HStack(spacing: 4) {
                            Button { move(id, by: -1) } label: { Image(systemName: "chevron.up") }
                                .disabled(index == 0)
                            Button { move(id, by: 1) } label: { Image(systemName: "chevron.down") }
                                .disabled(index == enabled.count - 1)
                            Button(role: .destructive) {
                                model.setEnabledSchemas(enabled.filter { $0 != id })
                            } label: { Image(systemName: "minus.circle") }
                                .disabled(enabled.count == 1)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            Section("可用方案") {
                ForEach(available.filter { !enabled.contains($0.id) }) { info in
                    SchemaRow(info: info, id: info.id, isDefault: false) {
                        Button("启用") { model.setEnabledSchemas(enabled + [info.id]) }
                    }
                }
            }
        }
        .formStyle(.cards)
    }

    private func move(_ id: String, by offset: Int) {
        var list = model.enabledSchemas
        guard let index = list.firstIndex(of: id), list.indices.contains(index + offset) else { return }
        list.swapAt(index, index + offset)
        model.setEnabledSchemas(list)
    }
}

private struct SchemaRow<Trailing: View>: View {
    let info: SchemaInfo?
    let id: String
    let isDefault: Bool
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(info?.name ?? id).font(.body.weight(.medium))
                    if isDefault {
                        Text("默认").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.accent.opacity(0.15), in: Capsule()).foregroundStyle(Theme.accentText)
                    }
                    if info?.fromUserDir == true {
                        Text("用户").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text([id, info?.author].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            trailing()
        }
        .padding(.vertical, 2)
    }
}
