import Foundation

/// Une AUHAL (`kAudioUnitSubType_HALOutput`), derrière un protocole : les appels réels d'AudioToolbox dans
/// l'exécutable (`AUHALUnit`), une fausse unité dans les tests. Chaque méthode est un seul appel à l'unité.
@MainActor
public protocol OutputUnit: AnyObject {
    /// `kAudioOutputUnitProperty_EnableIO` : 0 en entrée (bus 1), 1 en sortie (bus 0). Avant l'initialisation.
    func enableOutputOnly() throws
    /// `kAudioOutputUnitProperty_CurrentDevice`, relu sur l'unité.
    func currentDevice() throws -> DeviceID
    /// `kAudioOutputUnitProperty_CurrentDevice`, portée globale, bus 0. Avant l'initialisation.
    func setCurrentDevice(_ id: DeviceID) throws
    /// `kAudioUnitProperty_StreamFormat`, portée d'entrée, bus 0 (ce que talkd donne à l'unité).
    func setStreamFormat(_ format: PCMFormat) throws
    /// `kAudioUnitProperty_SetRenderCallback` avec `TalkRender.callback` et ce refCon.
    func setRenderCallback(refCon: UnsafeMutableRawPointer) throws
    func initialize() throws
    func uninitialize()
    /// `AudioOutputUnitStart`.
    func start() throws
    /// `AudioOutputUnitStop`.
    func stop()
    /// `kAudioOutputUnitProperty_IsRunning`, lu sur l'unité.
    var isRunning: Bool { get }
}

/// La sortie audio de talkd (spec haut-parleur § 4.1 et § 4.2, relecture C1 et I1) : une AUHAL en **sortie pure**.
///
/// - **Un seul client coreaudiod.** L'unité est créée une seule fois, à la première prise de parole, et gardée pour
///   toute la vie du process. `stop()` puis `start()` ne font qu'arrêter et redémarrer cette même unité.
/// - **Jamais le micro.** L'entrée est coupée (EnableIO à 0 sur le bus 1) avant l'initialisation : la sortie pure
///   est garantie par construction, sans la partie entrée d'`AVAudioEngine`.
/// - **Les haut-parleurs choisis.** `CurrentDevice` est réglé avant l'initialisation, puis relu sur l'unité à chaque
///   `start()` : si le système l'a changé (changement de configuration), il est réécrit. Rien n'est gardé en cache.
/// - **Le format** est celui de `TalkRender` (Float32, 16 kHz, deux canaux non entrelacés) ; l'AUHAL convertit.
/// - **Le rappel** est `TalkRender.callback`, une fonction C hors de tout acteur, qui lit `buffer`. La sortie garde le
///   tampon (référence forte) : le refCon donné à l'unité reste valide.
///
/// Un échec lève une erreur et n'est jamais retenté ici : le contrôleur réessaie à la prise de parole suivante, sur la
/// même unité.
@MainActor
public final class HALOutput: AudioOutput {
    private let makeUnit: () throws -> any OutputUnit
    private var unit: (any OutputUnit)?
    /// EnableIO réglé (une fois pour toute la vie de l'unité).
    private var outputOnly = false
    private var initialized = false
    /// Le tampon branché au rappel, gardé tant que l'unité peut l'appeler.
    private var buffer: JitterBuffer?

    public init(makeUnit: @escaping () throws -> any OutputUnit) {
        self.makeUnit = makeUnit
    }

    public var isRunning: Bool {
        unit?.isRunning ?? false
    }

    public func start(device: DeviceID, feeding buffer: JitterBuffer) throws {
        let unit = try self.unit ?? makeUnit()
        self.unit = unit
        if !outputOnly {
            try unit.enableOutputOnly()
            outputOnly = true
        }
        // Un autre périphérique (relu sur l'unité), ou un autre tampon : l'unité est arrêtée et désinitialisée avant
        // d'être reconfigurée.
        let deviceChanged = (try? unit.currentDevice()) != device
        let bufferChanged = self.buffer !== buffer
        if initialized, deviceChanged || bufferChanged {
            unit.stop()
            unit.uninitialize()
            initialized = false
        }
        if !initialized {
            try unit.setCurrentDevice(device)
            try unit.setStreamFormat(TalkRender.format)
            if bufferChanged {
                try unit.setRenderCallback(refCon: Unmanaged.passUnretained(buffer).toOpaque())
                self.buffer = buffer
            }
            try unit.initialize()
            initialized = true
        }
        try unit.start()
    }

    public func stop() {
        unit?.stop()
    }
}
