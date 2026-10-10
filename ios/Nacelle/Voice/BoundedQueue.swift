/// File d'attente bornée qui jette le plus ancien élément quand elle est pleine : pour la voix, mieux vaut perdre
/// 20 ms de retard que d'accumuler du retard (spec parler § 6.2).
struct BoundedQueue<Element> {
    let capacity: Int
    private var elements: [Element] = []
    /// Éléments jetés faute de place depuis la création ou la dernière remise à zéro.
    private(set) var droppedCount = 0

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        elements.reserveCapacity(capacity + 1)
    }

    var count: Int {
        elements.count
    }

    /// Ajoute `element` ; vrai si le plus ancien a dû être jeté pour lui faire de la place.
    @discardableResult
    mutating func push(_ element: Element) -> Bool {
        elements.append(element)
        guard elements.count > capacity else { return false }
        elements.removeFirst()
        droppedCount += 1
        return true
    }

    /// Reprend le plus ancien.
    mutating func pop() -> Element? {
        elements.isEmpty ? nil : elements.removeFirst()
    }

    mutating func removeAll() {
        elements.removeAll(keepingCapacity: true)
        droppedCount = 0
    }
}
