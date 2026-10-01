import AIMECore
import SwiftUI

/// 常用语: snippets in the user's own categories (证件, 手机号, 地址…), picked from the
/// quick menu with a digit for the category and a letter for the item.
struct SnippetsView: View {
    @Environment(SettingsModel.self) private var model

    var body: some View {
        let snippets = model.snippets
        Form {
            Section {
                PaneHeader(title: "常用语", subtitle: "把常用的内容按分类存好：证件号、手机号、地址、常用回复……打字时长按呼出键 → 1 常用语，数字切换分类，字母直接上屏。",
                           symbol: "list.bullet.rectangle")
            }

            if snippets.categories.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("还没有分类").font(.body.weight(.medium))
                        Text("从下面选一个常见分类开始，或者新建自己的。").font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            ForEach(Snippets.presetNames.prefix(5), id: \.self) { name in
                                Button(name) { model.updateSnippets { $0.categories.append(.init(name: name, items: [""])) } }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            ForEach(Array(snippets.categories.enumerated()), id: \.element.id) { index, category in
                Section {
                    ForEach(Array(category.items.enumerated()), id: \.offset) { itemIndex, item in
                        HStack(spacing: 10) {
                            CommitTextField(value: item, placeholder: "内容", maxWidth: .infinity) { text in
                                model.updateSnippets { snippets in
                                    guard let c = snippets.categories.firstIndex(where: { $0.id == category.id }),
                                          snippets.categories[c].items.indices.contains(itemIndex) else { return }
                                    snippets.categories[c].items[itemIndex] = text
                                }
                            }
                            Button(role: .destructive) {
                                model.updateSnippets { snippets in
                                    guard let c = snippets.categories.firstIndex(where: { $0.id == category.id }),
                                          snippets.categories[c].items.indices.contains(itemIndex) else { return }
                                    snippets.categories[c].items.remove(at: itemIndex)
                                }
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .help("删除这一条")
                        }
                    }
                    Button {
                        model.updateSnippets { snippets in
                            if let c = snippets.categories.firstIndex(where: { $0.id == category.id }) { snippets.categories[c].items.append("") }
                        }
                    } label: { Label("添加一条", systemImage: "plus") }
                        .buttonStyle(.borderless)
                } header: {
                    HStack(spacing: 8) {
                        // The digit that switches to this category in the quick menu.
                        Text(index < 9 ? "\(index + 1)" : index == 9 ? "0" : "·")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .frame(width: 18, height: 18)
                            .background(Theme.divider, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        CommitTextField(value: category.name, placeholder: "分类名称") { name in
                            model.updateSnippets { snippets in
                                if let c = snippets.categories.firstIndex(where: { $0.id == category.id }) { snippets.categories[c].name = name }
                            }
                        }
                        .frame(width: 180)
                        Spacer()
                        if index > 0 {
                            Button {
                                model.updateSnippets { $0.categories.swapAt(index, index - 1) }
                            } label: { Image(systemName: "arrow.up") }
                                .buttonStyle(.borderless).help("上移（数字键顺序随之变化）")
                        }
                        Button(role: .destructive) {
                            model.updateSnippets { $0.categories.removeAll { $0.id == category.id } }
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("删除分类")
                    }
                }
            }

            Section {
                Menu {
                    ForEach(Snippets.presetNames.filter { name in !snippets.categories.contains { $0.name == name } }, id: \.self) { name in
                        Button(name) { model.updateSnippets { $0.categories.append(.init(name: name, items: [""])) } }
                    }
                    Divider()
                    Button("自定义分类…") { model.updateSnippets { $0.categories.append(.init(name: "新分类", items: [""])) } }
                } label: {
                    Label("添加分类", systemImage: "folder.badge.plus")
                }
                .fixedSize()
            } footer: {
                Text("常用语只保存在这台 Mac 上（aime/snippets.json，仅本人可读），不上传、不进词库、不提供给 AI。「自定义短语」里的内容会作为最后一个分类「短语」一起显示。")
            }
        }
        .formStyle(.cards)
    }
}
