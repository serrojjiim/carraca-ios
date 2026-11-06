import SwiftUI
import UserNotifications
import AVFoundation

/// Pedir valoración en la App Store "cada x tiempo".
/// Se usa la ventanita oficial de Apple (obligatorio: no se permiten avisos propios). Apple además
/// no la enseña a quien ya ha valorado la versión y como mucho 3 veces al año; en TestFlight nunca sale.
enum ReviewPrompt {
    private static let d = UserDefaults.standard
    private static let firstKey = "carraca.review.first"
    private static let launchesKey = "carraca.review.launches"
    private static let lastKey = "carraca.review.last"

    /// Cada cuántos días como mínimo se vuelve a pedir.
    static let everyDays: Double = 30

    static func countLaunch() {
        if d.object(forKey: firstKey) == nil { d.set(Date(), forKey: firstKey) }
        d.set(d.integer(forKey: launchesKey) + 1, forKey: launchesKey)
    }

    /// Tras unos usos (4 aperturas y 2 días desde la primera) y si hace más de `everyDays` de la última vez.
    static var shouldAsk: Bool {
        guard let first = d.object(forKey: firstKey) as? Date else { return false }
        let day: Double = 86_400
        guard d.integer(forKey: launchesKey) >= 4, Date().timeIntervalSince(first) >= 2 * day else { return false }
        if let last = d.object(forKey: lastKey) as? Date, Date().timeIntervalSince(last) < everyDays * day { return false }
        return true
    }

    static func markAsked() { d.set(Date(), forKey: lastKey) }
}

/// Controla qué orientaciones permite la app en cada momento (el reproductor fuerza horizontal en iPhone).
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .allButUpsideDown
    /// Pestaña que abrir al tocar un aviso (si la app aún no tenía las pestañas en pantalla).
    static var pendingTab: String?
    static let openTab = Notification.Name("carraca.openTab")

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : Self.orientationLock
    }

    /// iOS despierta la app cuando acaba una descarga hecha con la app cerrada.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            Downloads.shared.backgroundCompletions[identifier] = completionHandler
            _ = Downloads.shared.items     // crea la sesión y se reengancha
        }
    }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Task { @MainActor in _ = Downloads.shared.items }   // retoma descargas pendientes
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// Aviso de un evento con la app abierta: se enseña igual.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    /// Tocar el aviso: a la pestaña de Eventos.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let tab = response.notification.request.content.userInfo["tab"] as? String {
            DispatchQueue.main.async {
                Self.pendingTab = tab
                NotificationCenter.default.post(name: Self.openTab, object: tab)
            }
        }
        completionHandler()
    }
}

@main
struct CarracaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var session = Session()
    @StateObject private var store = Store()

    init() {
        ReviewPrompt.countLaunch()
        ImageLoader.trim()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        // las imágenes van por su propia caché (ImageLoader); esta queda para lo demás
        URLCache.shared = URLCache(memoryCapacity: 16 << 20, diskCapacity: 50 << 20)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var store: Store
    @ObservedObject private var theme = ThemeStore.shared
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Group {
            if !session.isLoggedIn {
                LoginView()
            } else if !store.checked {
                LoadingView()
            } else if store.isPremium || store.testFlightBypass {
                MainTabView()
            } else {
                PaywallView()
            }
        }
        .overlay { SeasonDecor() }
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        .animation(.easeInOut(duration: 0.4), value: theme.current?.id)
        .seasonTint()
        .task { await ThemeStore.shared.refresh(force: true) }
        .onChange(of: phase) { p in
            if p == .active { Task { await ThemeStore.shared.refresh() } }
        }
        .onOpenURL { session.handle(url: $0) }
        .alert("Nueva versión disponible",
               isPresented: Binding(get: { session.update != nil }, set: { if !$0 { session.update = nil } })) {
            Button("Actualizar") {
                if let s = session.update?.iosInstallURL, let u = URL(string: s) { UIApplication.shared.open(u) }
            }
            Button("Más tarde", role: .cancel) {}
        } message: {
            Text("Hay una versión nueva de Carraca lista para instalar.")
        }
    }
}
