import AVFoundation
import NacelleProtocol
import SwiftUI
import VisionKit

/// Lecteur de QR code plein écran (spec découverte et QR § 8.1 et § 8.3) : le premier QR d'appairage
/// reconnu est rendu une fois ; un autre QR affiche « QR code non reconnu » et la lecture continue.
struct QRScannerView: View {
    let onLink: (PairingLink) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var access = CameraAccess.current
    @State private var message: String?
    @State private var done = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Scanner le QR code")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Annuler") {
                            dismiss()
                        }
                    }
                }
        }
        .task {
            if DataScannerViewController.isSupported, access == .undetermined {
                access = await AVCaptureDevice.requestAccess(for: .video) ? .granted : .denied
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !DataScannerViewController.isSupported {
            ContentUnavailableView(
                "Lecteur indisponible",
                systemImage: "qrcode.viewfinder",
                description: Text("Cet appareil ne lit pas les QR codes avec l'appareil photo.")
            )
        } else {
            scanner
        }
    }

    @ViewBuilder
    private var scanner: some View {
        switch access {
        case .granted:
            ZStack(alignment: .bottom) {
                DataScanner { payload in
                    guard !done else { return }
                    if let link = PairingLink(string: payload) {
                        done = true
                        onLink(link)
                    } else {
                        message = "QR code non reconnu"
                    }
                }
                .ignoresSafeArea()
                Text(message ?? "Visez le QR code affiché sur le Mac.")
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 32)
            }
        case .denied:
            ContentUnavailableView {
                Label("Appareil photo refusé", systemImage: "camera.fill")
            } description: {
                Text("Autorisez l'appareil photo pour PTZBot dans les Réglages d'iOS.")
            } actions: {
                Button("Ouvrir les Réglages") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
            }
        case .undetermined:
            ProgressView()
        }
    }
}

/// Accès à l'appareil photo.
enum CameraAccess {
    case granted
    case denied
    case undetermined

    static var current: CameraAccess {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            .granted
        case .notDetermined:
            .undetermined
        default:
            .denied
        }
    }
}

/// `DataScannerViewController` limité aux QR codes : rend le texte de chaque QR reconnu.
private struct DataScanner: UIViewControllerRepresentable {
    let onPayload: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onPayload = onPayload
        if !scanner.isScanning {
            try? scanner.startScanning()
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPayload: onPayload)
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onPayload: (String) -> Void

        init(onPayload: @escaping (String) -> Void) {
            self.onPayload = onPayload
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for case let .barcode(barcode) in addedItems {
                if let payload = barcode.payloadStringValue {
                    onPayload(payload)
                }
            }
        }
    }
}
