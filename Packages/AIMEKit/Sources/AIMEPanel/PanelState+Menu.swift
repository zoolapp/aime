public import AIMECore
import Foundation

public extension PanelState {
    /// The panel state for a quick-menu board (symbols or 常用语): visible cells, tabs with
    /// their digit, the key on every cell and a hint line.
    init(board: QuickMenu.Board) {
        let visible = board.visibleRange
        self.init(candidates: board.items[visible].map { Candidate(label: "", text: $0) },
                  highlightedIndex: max(0, board.highlighted - visible.lowerBound))
        let keys = board.keys.prefix(visible.count).map(String.init)
        let hint = board.style == .grid
            ? "字母键 上屏   ⇧字母 连续输入   数字 切换分类   Esc 返回"
            : "字母键 上屏   数字 切换分类   ↑↓ 移动   Esc 返回"
        self.board = Board(tabs: board.categories.map(\.title), selectedTab: board.category, columns: board.columns,
                           visibleRows: board.visibleRows, firstRow: board.firstRow, totalRows: board.rowCount,
                           hint: hint, keyHints: Array(keys))
    }
}
