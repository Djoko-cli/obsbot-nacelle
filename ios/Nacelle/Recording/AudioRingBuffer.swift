import Synchronization

/// Tampon circulaire d'échantillons PCM 16 bits, sans verrou, pour un seul producteur (le fil audio temps
/// réel de `PlayoutAudioDevice`) et un seul consommateur (la file du `ClipRecorder`).
///
/// Côté producteur (`write`, `writeSilence`) : aucune allocation, aucun verrou, aucune attente ; la
/// mémoire est réservée une fois pour toutes à l'init. Les échantillons sont rangés par blocs, chacun
/// avec l'heure d'arrivée de son premier échantillon (horloge de l'hôte, en nanosecondes).
///
/// Plein : le bloc qui ne tient pas est refusé en entier et compté dans `droppedSamples`. Les plus anciens
/// échantillons ne sont donc pas effacés (écart à la spec § 4.2, qui disait l'inverse) : faire avancer
/// l'indice de lecture depuis le producteur obligerait le consommateur à relire des données peut-être
/// déjà réécrites. L'effet est le même pour un enregistrement, un trou de la même durée, et le
/// `ClipRecorder` le comble par du silence d'après les heures des blocs.
///
/// `@unchecked Sendable` : le producteur est seul à écrire `storage` et `blocks` (en deçà des indices
/// publiés), le consommateur est seul à les lire (en deçà des mêmes indices). Les indices sont des
/// atomiques : le producteur publie avec `releasing`, le consommateur lit avec `acquiring`, et inversement
/// pour la place libérée.
final class AudioRingBuffer: @unchecked Sendable {
    /// Un bloc rendu au consommateur.
    struct Block: Equatable {
        var samples: [Int16]
        /// Heure d'arrivée du premier échantillon (`HostClock.nowNanoseconds()`).
        var time: UInt64
    }

    /// Un bloc rangé : position du premier échantillon, nombre d'échantillons, heure.
    private struct Entry {
        var start: Int
        var count: Int
        var time: UInt64
    }

    let capacity: Int
    private let entryCapacity: Int
    private let storage: UnsafeMutablePointer<Int16>
    private let entries: UnsafeMutablePointer<Entry>

    /// Échantillons publiés, depuis le début (jamais décrémenté).
    private let written = Atomic<Int>(0)
    private let read = Atomic<Int>(0)
    /// Blocs publiés, puis blocs repris.
    private let entriesWritten = Atomic<Int>(0)
    private let entriesRead = Atomic<Int>(0)
    private let dropped = Atomic<Int>(0)

    /// `capacity` : échantillons (images × canaux). `maxBlocks` : blocs en attente au plus.
    init(capacity: Int, maxBlocks: Int = 512) {
        self.capacity = capacity
        entryCapacity = maxBlocks
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
        entries = .allocate(capacity: maxBlocks)
        entries.initialize(repeating: Entry(start: 0, count: 0, time: 0), count: maxBlocks)
    }

    deinit {
        storage.deallocate()
        entries.deallocate()
    }

    /// Échantillons refusés faute de place depuis la dernière remise à zéro.
    var droppedSamples: Int {
        dropped.load(ordering: .relaxed)
    }

    // MARK: Producteur (fil audio temps réel)

    /// Range `count` échantillons arrivés à `time`. Faux, sans attendre, si le bloc ne tient pas.
    @discardableResult
    func write(_ samples: UnsafePointer<Int16>, count: Int, time: UInt64) -> Bool {
        publish(count: count, time: time) { target, length, offset in
            target.update(from: samples + offset, count: length)
        }
    }

    /// Range `count` échantillons nuls.
    @discardableResult
    func writeSilence(count: Int, time: UInt64) -> Bool {
        publish(count: count, time: time) { target, length, _ in
            target.update(repeating: 0, count: length)
        }
    }

    /// `fill(cible, longueur, décalage dans le bloc)` est appelé une ou deux fois (le bloc peut franchir la
    /// fin du tampon).
    private func publish(
        count: Int,
        time: UInt64,
        fill: (UnsafeMutablePointer<Int16>, Int, Int) -> Void
    ) -> Bool {
        let head = written.load(ordering: .relaxed)
        let tail = read.load(ordering: .acquiring)
        let entryHead = entriesWritten.load(ordering: .relaxed)
        let entryTail = entriesRead.load(ordering: .acquiring)
        guard count > 0, count <= capacity - (head - tail), entryHead - entryTail < entryCapacity else {
            dropped.wrappingAdd(max(count, 0), ordering: .relaxed)
            return false
        }
        let offset = head % capacity
        let first = min(count, capacity - offset)
        fill(storage + offset, first, 0)
        if first < count {
            fill(storage, count - first, first)
        }
        entries[entryHead % entryCapacity] = Entry(start: head, count: count, time: time)
        // Les données avant l'entrée : le consommateur ne voit l'entrée qu'une fois les deux publiés.
        written.store(head + count, ordering: .releasing)
        entriesWritten.store(entryHead + 1, ordering: .releasing)
        return true
    }

    // MARK: Consommateur (file du ClipRecorder)

    /// Aucun bloc en attente.
    var isEmpty: Bool {
        entriesRead.load(ordering: .relaxed) >= entriesWritten.load(ordering: .acquiring)
    }

    /// Reprend le plus ancien bloc, ou rien s'il n'y en a pas. Alloue : jamais sur le fil temps réel.
    func pop() -> Block? {
        let entryTail = entriesRead.load(ordering: .relaxed)
        guard entryTail < entriesWritten.load(ordering: .acquiring) else { return nil }
        let entry = entries[entryTail % entryCapacity]
        let offset = entry.start % capacity
        let first = min(entry.count, capacity - offset)
        var samples = [Int16](repeating: 0, count: entry.count)
        samples.withUnsafeMutableBufferPointer { target in
            target.baseAddress!.update(from: storage + offset, count: first)
            if first < entry.count {
                (target.baseAddress! + first).update(from: storage, count: entry.count - first)
            }
        }
        read.store(entry.start + entry.count, ordering: .releasing)
        entriesRead.store(entryTail + 1, ordering: .releasing)
        return Block(samples: samples, time: entry.time)
    }

    /// Vide le tampon et remet le compteur à zéro. À n'appeler que si le producteur est à l'arrêt.
    func reset() {
        read.store(written.load(ordering: .acquiring), ordering: .releasing)
        entriesRead.store(entriesWritten.load(ordering: .acquiring), ordering: .releasing)
        dropped.store(0, ordering: .relaxed)
    }
}
