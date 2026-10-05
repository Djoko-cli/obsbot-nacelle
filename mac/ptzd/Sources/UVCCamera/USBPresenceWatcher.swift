import Foundation
import IOKit

/// Suit l'arrivée et le départ d'un périphérique USB, par notifications IOKit
/// sur la file principale. Le port IOKit garde un pointeur non retenu vers cet
/// objet et n'est jamais détruit : il doit vivre aussi longtemps que le processus.
@MainActor
final class USBPresenceWatcher {
    private let vendorID: Int
    private let productID: Int
    private let onChange: @MainActor (Bool) -> Void
    private var port: IONotificationPortRef?
    private var matchedIterator: io_iterator_t = 0
    private var terminatedIterator: io_iterator_t = 0

    init(vendorID: Int, productID: Int, onChange: @escaping @MainActor (Bool) -> Void) {
        self.vendorID = vendorID
        self.productID = productID
        self.onChange = onChange
    }

    /// Arme les notifications puis signale tout de suite la présence actuelle.
    func start() {
        guard port == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, matching(), { context, iterator in
            guard let context else { return }
            let watcher = Unmanaged<USBPresenceWatcher>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.drain(iterator, attached: true) }
        }, context, &matchedIterator)
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, matching(), { context, iterator in
            guard let context else { return }
            let watcher = Unmanaged<USBPresenceWatcher>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.drain(iterator, attached: false) }
        }, context, &terminatedIterator)
        drain(terminatedIterator, attached: false)
        drain(matchedIterator, attached: true)
    }

    private func matching() -> CFDictionary {
        let dictionary = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
        dictionary["idVendor"] = vendorID
        dictionary["idProduct"] = productID
        return dictionary
    }

    /// Vide l'itérateur (ce qui réarme la notification) et signale s'il contenait quelque chose.
    private func drain(_ iterator: io_iterator_t, attached: Bool) {
        var found = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
            found = true
        }
        if found {
            onChange(attached)
        }
    }
}
