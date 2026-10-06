import NacelleProtocol
import SwiftUI

/// Tant que l'iPhone n'est pas appairé (spec découverte et QR § 8.1) : les Mac trouvés sur le Wi-Fi,
/// le lecteur de QR code et l'accès aux réglages (adresse de repli).
struct PairingScreen: View {
    @Bindable var model: AppModel
    @State private var discovery = Discovery(listing: BonjourServiceList())
    @State private var showScanner = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(discovery.macs, id: \.self) { name in
                        Label(name, systemImage: "desktopcomputer")
                    }
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Recherche du Mac à proximité…")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Sur le Wi-Fi")
                } footer: {
                    Text("Sur le Mac, lance ptzd pair dans le Terminal, puis scanne le QR code affiché.")
                }
                Section {
                    Button {
                        showScanner = true
                    } label: {
                        Label("Scanner le QR code", systemImage: "qrcode.viewfinder")
                    }
                    if let status = model.pairingStatus {
                        Text(status)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("PTZBot")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Réglages")
                }
            }
        }
        .onAppear {
            discovery.start()
        }
        .onDisappear {
            discovery.stop()
        }
        .sheet(isPresented: $showScanner) {
            QRScannerView { link in
                showScanner = false
                model.pair(with: link)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(
                settings: $model.settings,
                isPaired: model.ptz.isPaired,
                onPair: { model.pair(with: $0) },
                onForget: { model.forgetPairing() }
            )
        }
    }
}
