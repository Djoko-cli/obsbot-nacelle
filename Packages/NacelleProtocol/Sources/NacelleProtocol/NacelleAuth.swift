import CryptoKit
import Foundation

/// Authentification d'un appareil appairé, partagée par ptzd et l'app (spec accès local § 5).
/// Clé ECDSA P-256 ; la clé publique circule au format x963, la signature au format DER.
public enum NacelleAuth {
    /// Longueur du défi, en octets.
    public static let nonceLength = 32

    /// Les 16 premiers octets du SHA-256 de la clé publique x963, en hexadécimal (32 caractères).
    public static func deviceID(publicKeyX963: Data) -> String {
        SHA256.hash(data: publicKeyX963).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Ce que l'app signe : `nacelle-auth-v1|<défi en base64>|<deviceID>`, en UTF-8.
    public static func signedPayload(nonce: Data, deviceID: String) -> Data {
        Data("nacelle-auth-v1|\(nonce.base64EncodedString())|\(deviceID)".utf8)
    }

    /// Preuve d'appairage : HMAC-SHA256 avec le secret du QR, sur
    /// `nacelle-pair-v1|<défi en base64>|<clé publique en base64>` (spec découverte et QR § 6).
    public static func pairingProof(secret: Data, nonce: Data, publicKeyX963: Data) -> Data {
        let message = Data("nacelle-pair-v1|\(nonce.base64EncodedString())|\(publicKeyX963.base64EncodedString())".utf8)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: secret)))
    }

    /// Vérifie une preuve d'appairage en temps constant.
    public static func verifyPairingProof(_ proof: Data, secret: Data, nonce: Data, publicKeyX963: Data) -> Bool {
        let message = Data("nacelle-pair-v1|\(nonce.base64EncodedString())|\(publicKeyX963.base64EncodedString())".utf8)
        return HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: message, using: SymmetricKey(data: secret))
    }

    /// Vrai si `signature` (DER) est celle de la clé `publicKeyX963` sur ce défi et cet appareil.
    /// Une clé ou une signature illisible donne faux.
    public static func verify(signature: Data, nonce: Data, deviceID: String, publicKeyX963: Data) -> Bool {
        guard let key = try? P256.Signing.PublicKey(x963Representation: publicKeyX963),
              let ecdsa = try? P256.Signing.ECDSASignature(derRepresentation: signature) else {
            return false
        }
        return key.isValidSignature(ecdsa, for: signedPayload(nonce: nonce, deviceID: deviceID))
    }
}
