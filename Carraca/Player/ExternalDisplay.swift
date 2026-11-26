import SwiftUI
import UIKit
import AVFoundation
import AVKit

/// Pantalla externa: duplicado de pantalla por AirPlay a una Apple TV o tele, o cable HDMI.
///
/// Con una pantalla externa conectada, el vídeo de VLC se dibuja en una ventana propia que ocupa esa
/// pantalla, y el iPhone/iPad solo muestra los controles. El proveedor admite una conexión por cuenta,
/// así que hay un único reproductor y no se abre nada más.
///
/// Se usa UIScreen y no escenas: el target no declara UIApplicationSceneManifest para pantallas externas
/// (el Info.plist sale de project.yml, que no se toca). El duplicado lo inicia el usuario desde el Centro
/// de control; el botón de AirPlay de los controles elige la salida de audio/vídeo, no el duplicado.
@MainActor
final class ExternalDisplay: ObservableObject {
    static let shared = ExternalDisplay()

    /// Hay una pantalla externa en uso.
    @Published private(set) var active = false
    /// Nombre de la salida AirPlay (la Apple TV), si la hay.
    @Published private(set) var routeName: String?

    /// Vista de la pantalla externa: aquí dibuja VLC mientras la pantalla esté conectada.
    /// Es transparente para que se vea el fondo negro y el texto de espera cuando no hay reproductor.
    let videoView: UIView = {
        let v = UIView()
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = false
        return v
    }()

    /// Reproductor abierto ahora mismo (lo registra PlayerView al aparecer).
    private weak var controller: VLCController?
    private var window: UIWindow?
    private var hint: UILabel?
    private var observers: [NSObjectProtocol] = []

    private init() {}

    /// Al arrancar la app: escucha conexiones y mira si ya hay una pantalla (espejo activo al abrir).
    func start() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        let names: [Notification.Name] = [
            UIScreen.didConnectNotification,
            UIScreen.didDisconnectNotification,
            AVAudioSession.routeChangeNotification
        ]
        for name in names {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        refresh()
    }

    /// PlayerView lo llama al aparecer: el vídeo va a donde toque (teléfono o pantalla externa).
    func bind(_ c: VLCController) {
        controller = c
        c.showVideo(in: active ? videoView : c.phoneVideoView)
        updateHint()
    }

    /// PlayerView lo llama al salir: el vídeo vuelve a la vista del teléfono.
    func unbind(_ c: VLCController) {
        guard controller === c else { return }
        controller = nil
        c.showVideo(in: c.phoneVideoView)
        updateHint()
    }

    private func refresh() {
        if let screen = UIScreen.screens.first(where: { $0 !== UIScreen.main }) {
            attach(to: screen)
        } else {
            detach()
        }
    }

    private func attach(to screen: UIScreen) {
        if window?.screen !== screen {
            dropWindow()
            let w = UIWindow(frame: screen.bounds)
            w.screen = screen
            let container = UIView(frame: w.bounds)
            container.backgroundColor = .black
            container.autoresizingMask = [.flexibleWidth, .flexibleHeight]

            let label = UILabel(frame: container.bounds)
            label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            label.numberOfLines = 0
            label.textAlignment = .center
            label.textColor = .white
            label.font = .systemFont(ofSize: 36, weight: .semibold)
            label.text = "Carraca\nElige algo en el iPhone"
            container.addSubview(label)

            videoView.frame = container.bounds
            videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(videoView)

            let root = UIViewController()
            root.view = container
            w.rootViewController = root
            w.isHidden = false
            window = w
            hint = label
        }
        updateHint()
        let wasActive = active
        active = true
        routeName = Self.airPlayName()
        if !wasActive {
            controller?.showVideo(in: videoView)
            // una sola conexión: la vista previa de canales se para antes de que el vídeo salga aquí
            NotificationCenter.default.post(name: .stopChannelPreviews, object: nil)
        }
    }

    private func detach() {
        guard active || window != nil else { return }
        dropWindow()
        let wasActive = active
        active = false
        routeName = nil
        if wasActive, let c = controller { c.showVideo(in: c.phoneVideoView) }
    }

    private func dropWindow() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        hint = nil
        videoView.removeFromSuperview()
    }

    /// El texto de espera solo se ve sin reproductor (con vídeo, las barras negras no deben mostrarlo).
    private func updateHint() {
        hint?.isHidden = controller != nil
    }

    private static func airPlayName() -> String? {
        AVAudioSession.sharedInstance().currentRoute.outputs
            .first { $0.portType == .airPlay }?.portName
    }
}

/// Lo que ve el iPhone mientras el vídeo sale por la pantalla externa (sin vídeo, solo el aviso).
struct ExternalPlaybackNotice: View {
    let routeName: String?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "airplayvideo")
                .font(.system(size: 56))
            Text(routeName.map { "Reproduciendo en \($0)" } ?? "Reproduciendo en pantalla externa")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("El vídeo se ve en la pantalla conectada.")
                .font(.subheadline)
                .opacity(0.7)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Botón de AirPlay para elegir la salida (Apple TV). Para el duplicado, la pantalla se activa desde el Centro de control.
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView(frame: .zero)
        v.prioritizesVideoDevices = true
        v.tintColor = .white
        v.activeTintColor = .white
        v.accessibilityLabel = "Elegir dónde reproducir"
        return v
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
