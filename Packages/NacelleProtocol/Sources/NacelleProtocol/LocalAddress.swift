/// Adresses IPv4 du réseau local (spec app Mac § 9) : celles qu'un QR code peut contenir et celles
/// que l'app joint en TLS.
public enum LocalAddress {
    /// Les 4 octets d'une adresse IPv4 écrite en décimal pointé, ou nil.
    public static func octets(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { part in
            part.count <= 3 && part.allSatisfy { $0.isASCII && $0.isNumber } ? UInt8(part) : nil
        }
        return octets.count == 4 ? octets : nil
    }

    /// IPv4 privée : 10/8, 172.16/12, 192.168/16.
    public static func isPrivateIPv4(_ text: String) -> Bool {
        guard let o = octets(text) else { return false }
        switch (o[0], o[1]) {
        case (10, _), (172, 16...31), (192, 168):
            return true
        default:
            return false
        }
    }

    /// IPv4 privée ou d'auto-attribution (169.254/16).
    public static func isLocalIPv4(_ text: String) -> Bool {
        guard let o = octets(text) else { return false }
        return isPrivateIPv4(text) || (o[0] == 169 && o[1] == 254)
    }
}
