import Foundation
import Testing
@testable import TalkCore

/// Une fausse AUHAL : elle note chaque appel, dans l'ordre, et ne touche à aucun périphérique.
@MainActor
final class FakeOutputUnit: OutputUnit {
    struct Refused: Error, CustomStringConvertible {
        var description: String { "refusé par coreaudiod" }
    }

    private(set) var calls: [String] = []
    /// Le périphérique de l'unité, tel que l'unité le rapporte (le système peut le changer).
    var device: DeviceID?
    var running = false
    var initialized = false
    var failInitialize = false
    var failStart = false
    private(set) var refCon: UnsafeMutableRawPointer?

    func enableOutputOnly() throws {
        precondition(!initialized, "EnableIO après l'initialisation")
        calls.append("enableIO entrée 0, sortie 1")
    }

    func currentDevice() throws -> DeviceID {
        guard let device else { throw Refused() }
        return device
    }

    func setCurrentDevice(_ id: DeviceID) throws {
        precondition(!initialized, "CurrentDevice après l'initialisation")
        calls.append("périphérique \(id)")
        device = id
    }

    func setStreamFormat(_ format: PCMFormat) throws {
        precondition(!initialized, "format après l'initialisation")
        calls.append("format \(Int(format.sampleRate)) Hz, \(format.channels) canaux\(format.interleaved ? "" : " non entrelacés")")
    }

    func setRenderCallback(refCon: UnsafeMutableRawPointer) throws {
        precondition(!initialized, "rappel après l'initialisation")
        calls.append("rappel")
        self.refCon = refCon
    }

    func initialize() throws {
        calls.append("initialisation")
        if failInitialize {
            failInitialize = false
            throw Refused()
        }
        initialized = true
    }

    func uninitialize() {
        calls.append("désinitialisation")
        initialized = false
    }

    func start() throws {
        precondition(initialized, "démarrage d'une unité non initialisée")
        calls.append("démarrage")
        if failStart {
            failStart = false
            throw Refused()
        }
        running = true
    }

    func stop() {
        calls.append("arrêt")
        running = false
    }

    var isRunning: Bool {
        running
    }
}

@MainActor
@Suite("Sortie HAL (AUHAL en sortie pure)")
struct HALOutputTests {
    let buffer = JitterBuffer()

    /// Une sortie dont la fabrique d'unités compte ses appels.
    @MainActor
    final class Factory {
        var units: [FakeOutputUnit] = []
        var failNext = false

        func make() throws -> any OutputUnit {
            if failNext {
                failNext = false
                throw FakeOutputUnit.Refused()
            }
            let unit = FakeOutputUnit()
            units.append(unit)
            return unit
        }
    }

    private func output() -> (HALOutput, Factory) {
        let factory = Factory()
        return (HALOutput { try factory.make() }, factory)
    }

    @Test("Rien n'est créé avant la première prise de parole")
    func lazy() {
        let (output, factory) = output()
        #expect(factory.units.isEmpty)
        #expect(!output.isRunning)
        output.stop()
        #expect(factory.units.isEmpty)
    }

    @Test("Premier démarrage : une unité, sortie seule (EnableIO), périphérique, format et rappel AVANT l'initialisation, puis démarrage")
    func firstStart() throws {
        let (output, factory) = output()
        try output.start(device: 41, feeding: buffer)
        #expect(factory.units.count == 1)
        let unit = try #require(factory.units.first)
        #expect(unit.calls == [
            "enableIO entrée 0, sortie 1",
            "périphérique 41",
            "format 16000 Hz, 2 canaux non entrelacés",
            "rappel",
            "initialisation",
            "démarrage",
        ])
        #expect(output.isRunning)
        // Le rappel reçoit le tampon donné, sans le retenir (la sortie le garde, elle).
        #expect(unit.refCon == Unmanaged.passUnretained(buffer).toOpaque())
    }

    @Test("Arrêt puis redémarrage, dix fois : toujours la même unité, jamais recréée ni réinitialisée (un seul client coreaudiod)")
    func tenCycles() throws {
        let (output, factory) = output()
        for _ in 0..<10 {
            try output.start(device: 41, feeding: buffer)
            output.stop()
        }
        #expect(factory.units.count == 1)
        let unit = try #require(factory.units.first)
        #expect(unit.calls.filter { $0 == "initialisation" }.count == 1)
        #expect(unit.calls.filter { $0 == "enableIO entrée 0, sortie 1" }.count == 1)
        #expect(unit.calls.filter { $0 == "démarrage" }.count == 10)
        #expect(unit.calls.filter { $0 == "arrêt" }.count == 10)
        #expect(!output.isRunning)
    }

    @Test("Autre périphérique : arrêt, désinitialisation, nouveau périphérique et format, initialisation, démarrage ; même unité")
    func deviceChange() throws {
        let (output, factory) = output()
        try output.start(device: 41, feeding: buffer)
        let unit = try #require(factory.units.first)
        let before = unit.calls.count
        try output.start(device: 77, feeding: buffer)
        #expect(Array(unit.calls[before...]) == [
            "arrêt",
            "désinitialisation",
            "périphérique 77",
            "format 16000 Hz, 2 canaux non entrelacés",
            "initialisation",
            "démarrage",
        ])
        #expect(factory.units.count == 1)
    }

    @Test("Le périphérique est relu sur l'unité, pas gardé en cache : changé par le système, il est réécrit au démarrage suivant")
    func deviceReadFromUnit() throws {
        let (output, factory) = output()
        try output.start(device: 41, feeding: buffer)
        output.stop()
        let unit = try #require(factory.units.first)
        // Après un changement de configuration, l'unité est revenue sur la sortie par défaut.
        unit.device = 99
        let before = unit.calls.count
        try output.start(device: 41, feeding: buffer)
        #expect(Array(unit.calls[before...]).contains("périphérique 41"))
        #expect(unit.device == 41)
        #expect(factory.units.count == 1)
    }

    @Test("isRunning est lu sur l'unité : une unité arrêtée par le système est vue arrêtée")
    func isRunningFromUnit() throws {
        let (output, factory) = output()
        try output.start(device: 41, feeding: buffer)
        #expect(output.isRunning)
        factory.units.first?.running = false
        #expect(!output.isRunning)
    }

    @Test("Initialisation refusée : erreur levée ; l'unité est gardée, et la tentative suivante la reconfigure sans en créer une autre")
    func initializeRefused() throws {
        let unit = FakeOutputUnit()
        unit.failInitialize = true
        var creations = 0
        let output = HALOutput {
            creations += 1
            return unit
        }
        #expect(throws: FakeOutputUnit.Refused.self) { try output.start(device: 41, feeding: buffer) }
        #expect(!output.isRunning)
        try output.start(device: 41, feeding: buffer)
        #expect(output.isRunning)
        #expect(creations == 1)
        #expect(unit.calls.filter { $0 == "initialisation" }.count == 2)
        #expect(unit.calls.filter { $0 == "enableIO entrée 0, sortie 1" }.count == 1)
    }

    @Test("Démarrage refusé : erreur levée, rien n'est retenté ; la tentative suivante redémarre la même unité")
    func startRefused() throws {
        let (output, factory) = output()
        try output.start(device: 41, feeding: buffer)
        output.stop()
        let unit = try #require(factory.units.first)
        unit.failStart = true
        let before = unit.calls.count
        #expect(throws: FakeOutputUnit.Refused.self) { try output.start(device: 41, feeding: buffer) }
        #expect(unit.calls.count == before + 1)
        try output.start(device: 41, feeding: buffer)
        #expect(output.isRunning)
        #expect(factory.units.count == 1)
    }

    @Test("Création refusée : erreur levée, rien n'est gardé ; une seule tentative par démarrage")
    func creationRefused() throws {
        let (output, factory) = output()
        factory.failNext = true
        #expect(throws: FakeOutputUnit.Refused.self) { try output.start(device: 41, feeding: buffer) }
        #expect(factory.units.isEmpty)
        try output.start(device: 41, feeding: buffer)
        #expect(factory.units.count == 1)
    }

    @Test("Un autre tampon : le rappel est rebranché sur lui, unité arrêtée et désinitialisée d'abord, même unité")
    func otherBuffer() throws {
        let (output, factory) = output()
        try output.start(device: 41, feeding: buffer)
        let other = JitterBuffer()
        try output.start(device: 41, feeding: other)
        let unit = try #require(factory.units.first)
        #expect(unit.refCon == Unmanaged.passUnretained(other).toOpaque())
        #expect(factory.units.count == 1)
        #expect(output.isRunning)
    }
}
