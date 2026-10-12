import AVFoundation

/// Une caméra ou un micro du Mac.
public struct CaptureDeviceInfo: Equatable, Hashable, Sendable {
    public var name: String
    /// Un appareil virtuel (extension caméra d'OBSBOT Center, d'OBS…) : jamais choisi d'office.
    public var isVirtual: Bool

    public init(name: String, isVirtual: Bool) {
        self.name = name
        self.isVirtual = isVirtual
    }
}

/// Les caméras et micros du Mac, derrière un protocole pour les tests. Les lister ne demande aucune autorisation.
public protocol CaptureDeviceCatalog: Sendable {
    func cameras() -> [CaptureDeviceInfo]
    func microphones() -> [CaptureDeviceInfo]
}

/// Les vrais appareils, par `AVCaptureDevice.DiscoverySession` (spec B3 § 3.6).
public struct AVFoundationDeviceCatalog: CaptureDeviceCatalog {
    /// `kIOAudioDeviceTransportTypeVirtual` (« virt »).
    static let virtualTransport: Int32 = 0x7669_7274

    public init() {}

    public func cameras() -> [CaptureDeviceInfo] {
        Self.list(AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified
        ).devices)
    }

    public func microphones() -> [CaptureDeviceInfo] {
        Self.list(AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices)
    }

    static func list(_ devices: [AVCaptureDevice]) -> [CaptureDeviceInfo] {
        devices.map { device in
            CaptureDeviceInfo(
                name: device.localizedName,
                isVirtual: device.transportType == virtualTransport || device.localizedName.localizedCaseInsensitiveContains("virtual")
            )
        }
    }
}

/// Le choix des appareils (spec B3 § 3.6).
public enum CaptureDeviceChoice {
    public static let brand = "OBSBOT"

    /// Le premier appareil dont le nom contient « OBSBOT », un vrai de préférence à un virtuel ; nil sans OBSBOT.
    public static func preferred(in devices: [CaptureDeviceInfo]) -> String? {
        let obsbot = devices.filter { $0.name.localizedCaseInsensitiveContains(brand) }
        return (obsbot.first { !$0.isVirtual } ?? obsbot.first)?.name
    }

    /// Le nom réglé s'il y en a un, sinon le choix par défaut ; nil si l'appareil n'est pas là.
    public static func resolve(configured: String?, in devices: [CaptureDeviceInfo]) -> String? {
        if let configured, !configured.isEmpty {
            return devices.contains { $0.name == configured } ? configured : nil
        }
        return preferred(in: devices)
    }
}
