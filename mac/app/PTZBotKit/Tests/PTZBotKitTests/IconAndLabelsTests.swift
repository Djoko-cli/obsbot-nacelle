import AppKit
import Foundation
import NacelleProtocol
import Testing
@testable import PTZBotKit

@Suite("Icône et libellés")
struct IconAndLabelsTests {
    @Test("Icône : image modèle de 18 points de haut, presque carrée, décrite")
    func icon() throws {
        let image = MenuBarIcon.image()
        #expect(image.isTemplate)
        #expect(image.size.height == 18)
        #expect(image.size.width >= 15 && image.size.width <= 18)
        #expect(image.accessibilityDescription == "PTZBot")
        let bitmap = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(bitmap.height == 18 || bitmap.height == 36)
    }

    @Test("Icône : l'objectif est évidé (anneau transparent) et son centre plein")
    func lensRing() throws {
        let context = try #require(CGContext(data: nil, width: 300, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: 300)
        context.scaleBy(x: 1, y: -1)
        MenuBarIcon.draw(in: context)
        let image = try #require(context.makeImage())
        func alpha(_ x: Int, _ y: Int) -> UInt8 {
            let data = CFDataGetBytePtr(image.dataProvider!.data)!
            return data[y * image.bytesPerRow + x * 4 + 3]
        }
        #expect(alpha(126, 76) == 255)
        #expect(alpha(126 + 31, 76) == 0)
        #expect(alpha(100, 40) == 255)
        #expect(alpha(160, 220) == 255)
    }

    @Test("Libellés : chemins, état du service, temps restant")
    func labels() {
        #expect(Labels.route(.localNetwork) == "Réseau local")
        #expect(Labels.route(.mac) == "Ce Mac")
        #expect(Labels.service(.unreachable) == "Ne répond pas")
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(Labels.remaining(until: now + 216, now: now) == "3:36")
        #expect(Labels.remaining(until: now - 5, now: now) == "0:00")
    }

    @Test("État d'un appareil : expulsé, connecté et par où, ou hors ligne")
    func deviceState() {
        let now = Date(timeIntervalSince1970: 1_791_300_000)
        let device = AdminDevice(deviceID: "1a2b", name: "iPhone", pairedAt: now, blockedUntil: nil)
        let client = AdminClient(id: 3, deviceID: "1a2b", name: "iPhone", route: .tailscale, address: "100.64.0.1", since: now)
        #expect(Labels.device(device, clients: [client], now: now) == "connecté · Tailscale")
        #expect(Labels.device(device, clients: [], now: now) == "hors ligne")
        var blocked = device
        blocked.blockedUntil = now + 600
        #expect(Labels.device(blocked, clients: [client], now: now).hasPrefix("expulsé jusqu'à "))
        blocked.blockedUntil = now - 1
        #expect(Labels.device(blocked, clients: [], now: now) == "hors ligne")
        #expect(Labels.client(AdminClient(id: 1, deviceID: nil, name: nil, route: .mac, address: "127.0.0.1", since: now)).title == "PTZBot")
    }
}
