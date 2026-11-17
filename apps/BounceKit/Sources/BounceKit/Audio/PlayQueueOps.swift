import Foundation

/// Pure queue-mutation rules for the player's Up Next list. `index` is the
/// position of the playing item; everything after it is "Up Next". These never
/// introduce duplicate ids, so id-based lookups of the current index stay valid.
public enum PlayQueueOps {
    /// The playback context for starting `item` from a list in `order`: `order`
    /// itself when it holds `item`; otherwise `order` with the first sibling
    /// (`isSibling`) replaced by `item`; otherwise `item` followed by `order`.
    /// The result always contains `item` exactly once.
    public static func context<T>(
        for item: T,
        id: KeyPath<T, UUID>,
        in order: [T],
        isSibling: (T) -> Bool = { _ in false }
    ) -> [T] {
        let itemID = item[keyPath: id]
        if order.contains(where: { $0[keyPath: id] == itemID }) { return order }
        if let sibling = order.firstIndex(where: isSibling) {
            var context = order
            context[sibling] = item
            return context
        }
        return [item] + order
    }

    /// Place `item` directly after the playing item. An existing entry is moved.
    /// Does nothing when `item` is the playing item. An empty/invalid queue
    /// becomes `[item]` (index 0).
    @discardableResult
    public static func playNext<T>(
        _ item: T,
        id: KeyPath<T, UUID>,
        queue: inout [T],
        index: inout Int
    ) -> Bool {
        guard queue.indices.contains(index) else {
            queue = [item]
            index = 0
            return true
        }
        let itemID = item[keyPath: id]
        if queue[index][keyPath: id] == itemID { return false }
        if let existing = queue.firstIndex(where: { $0[keyPath: id] == itemID }) {
            queue.remove(at: existing)
            if existing < index { index -= 1 }
        }
        queue.insert(item, at: index + 1)
        return true
    }

    /// Queue `item` behind the user's own queued entries (`queued`) that follow
    /// the playing item, ahead of the rest of the playback context. An entry
    /// already in the context is moved there. Currently playing or already
    /// queued by the user: unchanged.
    @discardableResult
    public static func addToQueue<T>(
        _ item: T,
        id: KeyPath<T, UUID>,
        queue: inout [T],
        index: inout Int,
        queued: Set<UUID>
    ) -> Bool {
        guard queue.indices.contains(index) else {
            queue = [item]
            index = 0
            return true
        }
        let itemID = item[keyPath: id]
        if let existing = queue.firstIndex(where: { $0[keyPath: id] == itemID }) {
            if existing == index { return false }
            if existing > index && queued.contains(itemID) { return false }
            queue.remove(at: existing)
            if existing < index { index -= 1 }
        }
        var position = index + 1
        while position < queue.count && queued.contains(queue[position][keyPath: id]) {
            position += 1
        }
        queue.insert(item, at: position)
        return true
    }

    /// Shuffle for playback: the playing item moves to the front, followed by
    /// the user's queued upcoming entries (`pinned`) in order, then every other
    /// entry in random order. `index` becomes 0.
    public static func shuffle<T, G: RandomNumberGenerator>(
        id: KeyPath<T, UUID>,
        pinned: Set<UUID>,
        queue: inout [T],
        index: inout Int,
        using generator: inout G
    ) {
        guard queue.indices.contains(index) else {
            queue.shuffle(using: &generator)
            index = 0
            return
        }
        let current = queue[index]
        let upcoming = queue[(index + 1)...]
        let pinnedUpcoming = upcoming.filter { pinned.contains($0[keyPath: id]) }
        var rest = Array(queue[..<index]) + upcoming.filter { !pinned.contains($0[keyPath: id]) }
        rest.shuffle(using: &generator)
        queue = [current] + pinnedUpcoming + rest
        index = 0
    }

    public static func shuffle<T>(
        id: KeyPath<T, UUID>,
        pinned: Set<UUID>,
        queue: inout [T],
        index: inout Int
    ) {
        var generator = SystemRandomNumberGenerator()
        shuffle(id: id, pinned: pinned, queue: &queue, index: &index, using: &generator)
    }

    /// Undo `shuffle`: entries go back to their position in `originalOrder`,
    /// except the user's queued upcoming entries (`pinned`), which stay directly
    /// after the playing item. Unknown upcoming ids go last in their current
    /// order; unknown already played ids are dropped. An unknown playing item
    /// is placed after the last known entry that preceded it. `index` follows
    /// the playing item.
    public static func unshuffle<T>(
        id: KeyPath<T, UUID>,
        pinned: Set<UUID>,
        originalOrder: [UUID],
        queue: inout [T],
        index: inout Int
    ) {
        guard queue.indices.contains(index) else { return }
        let current = queue[index]
        var rank: [UUID: Int] = [:]
        for (position, itemID) in originalOrder.enumerated() where rank[itemID] == nil {
            rank[itemID] = position
        }
        let pinnedUpcoming = queue[(index + 1)...].filter { pinned.contains($0[keyPath: id]) }
        let pinnedIDs = Set(pinnedUpcoming.map { $0[keyPath: id] })
        var ordered = queue.enumerated()
            .filter { entry in
                let entryID = entry.element[keyPath: id]
                if entry.offset == index || pinnedIDs.contains(entryID) { return false }
                return entry.offset > index || rank[entryID] != nil
            }
            .sorted { lhs, rhs in
                let l = rank[lhs.element[keyPath: id]] ?? Int.max
                let r = rank[rhs.element[keyPath: id]] ?? Int.max
                return l == r ? lhs.offset < rhs.offset : l < r
            }
            .map(\.element)
        let currentPosition: Int
        if let currentRank = rank[current[keyPath: id]] {
            currentPosition = ordered.firstIndex { (rank[$0[keyPath: id]] ?? Int.max) > currentRank } ?? ordered.count
        } else if let anchor = queue[..<index].last(where: { rank[$0[keyPath: id]] != nil }),
                  let anchorPosition = ordered.firstIndex(where: { $0[keyPath: id] == anchor[keyPath: id] }) {
            currentPosition = anchorPosition + 1
        } else {
            currentPosition = 0
        }
        ordered.insert(current, at: currentPosition)
        ordered.insert(contentsOf: pinnedUpcoming, at: currentPosition + 1)
        queue = ordered
        index = currentPosition
    }

    /// Drop entries whose id is in `removed`, keeping `index` on the same
    /// playing item. If the playing item is removed the queue is emptied.
    public static func prune<T>(
        id: KeyPath<T, UUID>,
        removing removed: Set<UUID>,
        queue: inout [T],
        index: inout Int
    ) {
        if queue.indices.contains(index), removed.contains(queue[index][keyPath: id]) {
            queue = []
            index = 0
            return
        }
        let before = queue.prefix(index).filter { removed.contains($0[keyPath: id]) }.count
        queue.removeAll { removed.contains($0[keyPath: id]) }
        index = max(0, index - before)
    }
}
