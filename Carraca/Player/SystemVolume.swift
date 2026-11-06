import SwiftUI
import MediaPlayer

/// Volumen del sistema: Apple no deja cambiarlo directamente; se hace con el control de volumen
/// del sistema (MPVolumeView) puesto invisible en el reproductor. Mientras está en pantalla,
/// iOS tampoco enseña su aviso de volumen (enseñamos el nuestro).
enum SystemVolume {
    static weak var view: MPVolumeView?

    static func set(_ value: Float) {
        guard let slider = view?.subviews.compactMap({ $0 as? UISlider }).first else { return }
        slider.setValue(max(0, min(1, value)), animated: false)
        slider.sendActions(for: .valueChanged)
    }
}

struct SystemVolumeHost: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let v = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        v.isUserInteractionEnabled = false
        SystemVolume.view = v
        return v
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
