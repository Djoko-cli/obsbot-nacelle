import Foundation
import Network
import Security

/// Canal chiffré du réseau local (spec accès local § 14) : TLS 1.2 à clé pré-partagée, une clé par appareil,
/// identité TLS = `deviceID`. Réglages communs à ptzd et à l'app. Vérifié sur macOS 27 et iOS 27 :
/// TLS 1.3 n'accepte pas les clés pré-partagées ; sans couper la reprise de session, une mauvaise clé ou un
/// appareil retiré pourrait reprendre une session ; sans clé du tout, le serveur n'offre aucune suite PSK.
public enum NacelleTLS {
    /// Échange ECDHE en plus de la clé : confidentialité persistante. La constante est vue en `UInt32`
    /// (`SSLCipherSuite`) par certaines compilations (Release de l'app Mac) et en `UInt16` par d'autres :
    /// la conversion vaut pour les deux (0xCCAC).
    static let cipherSuite = tls_ciphersuite_t(rawValue: UInt16(TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256))!
    /// Longueur du secret remis à l'appairage, en octets.
    public static let keyLength = 32

    /// Identité TLS d'un appairage en cours : `pair-<pairingID>` (spec découverte et QR § 7.1).
    public static func pairingIdentity(_ pairingID: String) -> String {
        "pair-\(pairingID)"
    }

    /// Un secret neuf.
    public static func makeKey() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<keyLength).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    /// Côté app : une seule clé, sous l'identité de l'appareil.
    public static func client(identity: String, key: Data) -> NWProtocolTLS.Options {
        let (tls, options) = base()
        sec_protocol_options_add_pre_shared_key(options, dispatchData(key), dispatchData(Data(identity.utf8)))
        return tls
    }

    /// Côté ptzd. Les clés de `identities` sont figées dans l'écoute : relancer l'écoute pour en ajouter.
    /// `keyFor` est relu à chaque poignée de main : un appareil retiré, ou dont la clé a changé depuis
    /// (réappairé sans relance de l'écoute), est refusé tout de suite.
    public static func server(identities: [String], keyFor: @escaping @Sendable (String) -> Data?) -> NWProtocolTLS.Options {
        let (tls, options) = base()
        // Une clé factice garde les suites PSK actives quand aucun appareil n'est appairé.
        sec_protocol_options_add_pre_shared_key(options, dispatchData(makeKey()), dispatchData(Data("aucun-appareil".utf8)))
        var pinned: [String: Data] = [:]
        for identity in identities {
            if let key = keyFor(identity) {
                pinned[identity] = key
                sec_protocol_options_add_pre_shared_key(options, dispatchData(key), dispatchData(Data(identity.utf8)))
            }
        }
        sec_protocol_options_set_pre_shared_key_selection_block(options, { [pinned] _, identityData, complete in
            guard let identityData,
                  let identity = String(bytes: identityData as DispatchData, encoding: .utf8),
                  let key = pinned[identity],
                  keyFor(identity) == key else {
                complete(nil)
                return
            }
            complete(identityData)
        }, DispatchQueue(label: "io.github.djoko-cli.nacelle.psk"))
        return tls
    }

    private static func base() -> (NWProtocolTLS.Options, sec_protocol_options_t) {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(options, cipherSuite)
        sec_protocol_options_set_tls_resumption_enabled(options, false)
        sec_protocol_options_set_tls_tickets_enabled(options, false)
        return (tls, options)
    }

    private static func dispatchData(_ data: Data) -> __DispatchData {
        data.withUnsafeBytes { DispatchData(bytes: $0) as __DispatchData }
    }
}
