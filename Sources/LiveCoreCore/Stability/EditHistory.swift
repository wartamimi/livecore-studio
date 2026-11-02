/// Undo / redo for an editor that works on one value (Layer Designer layers, a title design...).
///
/// `record` is called with every new value; changes that arrive within `coalesce` seconds of each
/// other (dragging a slider or a layer) become one undo step, so ⌘Z goes back to where the drag
/// started instead of one pixel. The history is bounded by `limit`.
public struct EditHistory<Value: Equatable> {
    public private(set) var current: Value
    private var undoStack: [Value] = []
    private var redoStack: [Value] = []
    private var lastRecord: Double = -.infinity
    public let limit: Int
    public let coalesce: Double

    public init(_ initial: Value, limit: Int = 100, coalesce: Double = 0.6) {
        current = initial
        self.limit = max(1, limit)
        self.coalesce = max(0, coalesce)
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoCount: Int { undoStack.count }

    /// A new value from the editor at time `now` (seconds, any monotonic clock).
    public mutating func record(_ value: Value, now: Double) {
        guard value != current else { return }
        if now - lastRecord > coalesce || undoStack.isEmpty {
            undoStack.append(current)
            if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        }
        current = value
        redoStack.removeAll()
        lastRecord = now
    }

    /// Starts a new undo step on the next `record`, even inside the coalescing window
    /// (a button press after a drag is its own step).
    public mutating func breakCoalescing() { lastRecord = -.infinity }

    /// The value to show after undo, nil when there is nothing to undo.
    @discardableResult
    public mutating func undo() -> Value? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        current = previous
        lastRecord = -.infinity
        return previous
    }

    @discardableResult
    public mutating func redo() -> Value? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        current = next
        lastRecord = -.infinity
        return next
    }

    /// Forgets the history and starts again from `value` (another input was opened).
    public mutating func reset(_ value: Value) {
        current = value
        undoStack.removeAll()
        redoStack.removeAll()
        lastRecord = -.infinity
    }
}
