import UIKit

/// Vibración suave para confirmar una acción (favorito, cambio de canal). En iPad no hace nada.
enum Haptics {
    static func light() {
        let g = UIImpactFeedbackGenerator(style: .light)
        g.prepare()
        g.impactOccurred()
    }
}
