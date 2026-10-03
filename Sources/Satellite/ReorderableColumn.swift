import AppKit
import SwiftUI

/// The arithmetic of dragging a row to a new place in a column of equally tall rows.
enum ReorderMath {
    /// The place a row dragged from `from` takes if it is let go after moving `translation` points down (negative: up).
    static func target(from: Int, translation: CGFloat, rowHeight: CGFloat, count: Int) -> Int {
        guard count > 0, rowHeight > 0 else { return from }
        return min(max(from + Int((translation / rowHeight).rounded()), 0), count - 1)
    }

    /// How far the dragged row may follow the pointer: not past the first or last place.
    static func clamped(translation: CGFloat, from: Int, rowHeight: CGFloat, count: Int) -> CGFloat {
        min(max(translation, -CGFloat(from) * rowHeight), CGFloat(max(count - 1 - from, 0)) * rowHeight)
    }

    /// How far another row is pushed aside while row `from` is being dragged over place `target`.
    static func shift(row: Int, from: Int, target: Int, rowHeight: CGFloat) -> CGFloat {
        if from < target, row > from, row <= target { return -rowHeight }
        if from > target, row >= target, row < from { return rowHeight }
        return 0
    }

    /// The `toOffset` of SwiftUI's `move(fromOffsets:toOffset:)` that puts row `from` in place `target`.
    static func destination(from: Int, target: Int) -> Int {
        target > from ? target + 1 : target
    }
}

/// The row being dragged, if any. Kept out of the view so what a drag does is plain code.
final class ReorderDragState: ObservableObject {
    struct Drag: Equatable {
        var id: AnyHashable
        var from: Int
        var translation: CGFloat
    }

    @Published private(set) var drag: Drag?

    /// Starts dragging the row `id` (at place `from`), or follows the pointer if it is already being dragged.
    func change(id: AnyHashable, from: Int, translation: CGFloat) {
        if var current = drag, current.id == id {
            current.translation = translation
            drag = current
        } else if drag == nil {
            drag = Drag(id: id, from: from, translation: translation)
        }
    }

    /// Where the dragged row would land now.
    func target(rowHeight: CGFloat, count: Int) -> Int? {
        drag.map { ReorderMath.target(from: $0.from, translation: $0.translation, rowHeight: rowHeight, count: count) }
    }

    /// Lets go of the row. Returns the move to make (SwiftUI's `fromOffsets`/`toOffset`), or nil if it stays where it was.
    func end(translation: CGFloat, rowHeight: CGFloat, count: Int) -> (from: Int, destination: Int)? {
        guard let current = drag else { return nil }
        drag = nil
        guard current.from < count else { return nil }
        let place = ReorderMath.target(from: current.from, translation: translation, rowHeight: rowHeight, count: count)
        return place == current.from ? nil : (current.from, ReorderMath.destination(from: current.from, target: place))
    }

    /// The drag was interrupted (the window lost the mouse, say): put the row down where it was.
    func cancel() {
        drag = nil
    }
}

/// The grip at the start of a row. Dragging it moves the row; the rest of the row is left alone, so buttons and
/// double-clicks in it keep working.
struct ReorderHandle: View {
    let rowHeight: CGFloat
    let onChange: (CGFloat) -> Void
    let onEnd: (CGFloat) -> Void
    let onAbort: () -> Void

    @GestureState private var isLive = false

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 26, height: rowHeight)
            .contentShape(Rectangle())
            .help("Drag to reorder")
            .onHover { inside in
                if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(ReorderableColumn<WebApp, EmptyView>.space))
                    .updating($isLive) { _, live, _ in live = true }
                    .onChanged { onChange($0.translation.height) }
                    .onEnded { onEnd($0.translation.height) })
            // A gesture that is cancelled never ends; the row would stay lifted.
            .onChange(of: isLive) { _, live in
                if !live { onAbort() }
            }
    }
}

/// A column of rows, each with a grip (`ReorderHandle`) to drag it up or down. The row follows the pointer and
/// the others slide out of its way; when it is let go, `move` is called with SwiftUI's `move(fromOffsets:toOffset:)` arguments.
struct ReorderableColumn<Item: Identifiable, Row: View>: View where Item.ID: Hashable {
    static var space: String { "reorderable-column" }

    let items: [Item]
    let rowHeight: CGFloat
    let move: (IndexSet, Int) -> Void
    let row: (Item, ReorderHandle) -> Row

    @StateObject private var state: ReorderDragState

    init(items: [Item], rowHeight: CGFloat, state: ReorderDragState? = nil, move: @escaping (IndexSet, Int) -> Void,
         @ViewBuilder row: @escaping (Item, ReorderHandle) -> Row) {
        self.items = items
        self.rowHeight = rowHeight
        self.move = move
        self.row = row
        _state = StateObject(wrappedValue: state ?? ReorderDragState())
    }

    var body: some View {
        let target = state.target(rowHeight: rowHeight, count: items.count)
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let dragging = state.drag?.id == AnyHashable(item.id)
                row(item, handle(for: item))
                    .frame(height: rowHeight)
                    .background(dragging ? Color(nsColor: .controlBackgroundColor) : Color.clear)
                    .overlay(alignment: .bottom) {
                        if index < items.count - 1, !dragging { Divider() }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: dragging ? 8 : 0))
                    .shadow(color: .black.opacity(dragging ? 0.22 : 0), radius: dragging ? 8 : 0, y: dragging ? 2 : 0)
                    .scaleEffect(dragging ? 1.01 : 1)
                    .offset(y: offset(of: index, dragging: dragging, target: target))
                    .zIndex(dragging ? 1 : 0)
                    .animation(dragging ? nil : .easeOut(duration: 0.14), value: target)
            }
        }
        .coordinateSpace(name: Self.space)
    }

    private func offset(of index: Int, dragging: Bool, target: Int?) -> CGFloat {
        guard let drag = state.drag else { return 0 }
        if dragging { return ReorderMath.clamped(translation: drag.translation, from: drag.from, rowHeight: rowHeight, count: items.count) }
        return ReorderMath.shift(row: index, from: drag.from, target: target ?? drag.from, rowHeight: rowHeight)
    }

    private func handle(for item: Item) -> ReorderHandle {
        ReorderHandle(
            rowHeight: rowHeight,
            onChange: { translation in
                guard let from = items.firstIndex(where: { $0.id == item.id }) else { return }
                state.change(id: AnyHashable(item.id), from: from, translation: translation)
            },
            onEnd: { translation in
                // The rows settle into their new order at once, with nothing animating back from where they were dragged.
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    if let result = state.end(translation: translation, rowHeight: rowHeight, count: items.count) {
                        move(IndexSet(integer: result.from), result.destination)
                    }
                }
            },
            onAbort: { state.cancel() })
    }
}
