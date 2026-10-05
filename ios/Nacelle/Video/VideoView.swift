import SwiftUI
@preconcurrency import WebRTC

/// L'image de la caméra, sans rognage (spec § 7.2).
struct VideoView: UIViewRepresentable {
    let session: VideoSession

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView(frame: .zero)
        view.videoContentMode = .scaleAspectFit
        view.backgroundColor = .black
        session.attach(renderer: view)
        return view
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {}
}
