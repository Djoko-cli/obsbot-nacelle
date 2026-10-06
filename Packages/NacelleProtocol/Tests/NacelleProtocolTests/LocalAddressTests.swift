import Testing
@testable import NacelleProtocol

@Suite("Adresses du réseau local")
struct LocalAddressTests {
    @Test("Privées : 10/8, 172.16/12, 192.168/16", arguments: ["10.0.0.5", "172.16.0.1", "172.31.255.1", "192.168.0.10"])
    func privateAddresses(_ text: String) {
        #expect(LocalAddress.isPrivateIPv4(text))
        #expect(LocalAddress.isLocalIPv4(text))
    }

    @Test("Auto-attribution : locale mais pas privée")
    func linkLocal() {
        #expect(LocalAddress.isLocalIPv4("169.254.0.1"))
        #expect(!LocalAddress.isPrivateIPv4("169.254.0.1"))
    }

    @Test("Refusées : autres plages, mal écrites", arguments: ["172.32.0.1", "100.64.0.1", "192.0.2.30", "192.168.0.300", "192.168.0", "192.168.0.10.1", "0192.168.0.1", "+10.0.0.5", "mac-mini.local", ""])
    func notLocal(_ text: String) {
        #expect(!LocalAddress.isLocalIPv4(text))
    }

    @Test("Octets")
    func octets() {
        #expect(LocalAddress.octets("192.168.0.10") == [192, 168, 0, 10])
        #expect(LocalAddress.octets("256.0.0.1") == nil)
    }
}
