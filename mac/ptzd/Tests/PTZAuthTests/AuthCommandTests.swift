import CryptoKit
import Foundation
import NacelleProtocol
import Testing
@testable import PTZAuth

@Suite("Commandes pair, devices et revoke")
struct AuthCommandTests {
    let authority: DeviceAuthority

    init() throws {
        authority = DeviceAuthority(directory: try makeTemporaryDirectory())
    }

    @Test("pair affiche un code qui marche")
    func pair() throws {
        let result = AuthCommand.run(["pair"], authority: authority)
        #expect(result.status == 0)
        let code = try #require(result.output.split(separator: "\n").first?.split(separator: " ").last.map(String.init))
        let key = P256.Signing.PrivateKey().publicKey.x963Representation
        #expect(authority.pair(code: code, publicKey: key, name: "iPhone") == .paired(deviceID: NacelleAuth.deviceID(publicKeyX963: key)))
    }

    @Test("devices : vide, puis une ligne par appareil")
    func devices() throws {
        #expect(AuthCommand.run(["devices"], authority: authority).output == "Aucun appareil appairé.")
        try authority.devices.add(PairedDevice(
            deviceID: "0123456789abcdef0123456789abcdef", name: "iPhone",
            publicKey: Data([4]), pairedAt: Date(timeIntervalSince1970: 1_791_288_000)
        ))
        #expect(AuthCommand.run(["devices"], authority: authority).output == "01234567  2026-10-06  iPhone")
    }

    @Test("revoke : retire, ou explique pourquoi pas")
    func revoke() throws {
        try authority.devices.add(PairedDevice(deviceID: "0123456789abcdef", name: "iPhone", publicKey: Data([4]), pairedAt: Date()))
        #expect(AuthCommand.run(["revoke", "9999"], authority: authority).status == 1)
        let result = AuthCommand.run(["revoke", "0123"], authority: authority)
        #expect(result.status == 0)
        #expect(result.output.hasPrefix("Retiré : 01234567  iPhone."))
        #expect(try authority.devices.all().isEmpty)
    }

    @Test("Arguments en trop ou inconnus : usage, code 2", arguments: [["pair", "x"], ["devices", "x"], ["revoke"], ["dance"]])
    func usage(_ arguments: [String]) {
        let result = AuthCommand.run(arguments, authority: authority)
        #expect(result.status == 2)
        #expect(result.output == AuthCommand.usage)
    }
}
