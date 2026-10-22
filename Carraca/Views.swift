import SwiftUI
import AVFoundation

/// Controla qué orientaciones permite la app en cada momento (el reproductor fuerza horizontal en iPhone).
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .allButUpsideDown

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : Self.orientationLock
    }
}

@main
struct CarracaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var session = Session()
    @StateObject private var store = Store()

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 400 << 20)
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

// MARK: - Login

struct LoginView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case xtream = "Servidor", m3u = "Lista M3U"
        var id: String { rawValue }
    }

    @EnvironmentObject private var session: Session
    @State private var mode = Mode.xtream
    @State private var server = ""
    @State private var user = ""
    @State private var pass = ""
    @State private var m3u = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 120)
                    .padding(.top, 56)
                Text("Carraca").font(.largeTitle.bold())

                Picker("Tipo", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 12) {
                    if mode == .xtream {
                        field(Flavor.isPrivate ? "Servidor (opcional)" : "Servidor, ej. http://servidor.com:8080",
                              text: $server, icon: "server.rack", keyboard: .URL)
                        if Flavor.isPrivate {
                            Text("Déjalo vacío para usar el servidor Carraca.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 4)
                        }
                        field("Usuario", text: $user, icon: "person", keyboard: .asciiCapable)
                        HStack {
                            Image(systemName: "lock").foregroundStyle(.secondary).frame(width: 22)
                            SecureField("Contraseña", text: $pass)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))
                    } else {
                        field("URL de la lista (http://…/lista.m3u)", text: $m3u, icon: "list.bullet.rectangle", keyboard: .URL)
                    }
                }

                if let error {
                    Text(error).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
                }

                Button {
                    Task { await doLogin() }
                } label: {
                    HStack(spacing: 10) {
                        if busy { ProgressView().tint(.white) }
                        Text("Entrar").bold()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(busy || !canSubmit)

                Text("Carraca es un reproductor: no incluye canales, películas ni ningún contenido. Necesitas tu propio servicio o lista.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .background(Color("LaunchBg").ignoresSafeArea())
        .onAppear(perform: applyPrefill)
        .onChange(of: session.prefill) { _ in applyPrefill() }
    }

    private var canSubmit: Bool {
        mode == .m3u ? !m3u.isEmpty : (!user.isEmpty && !pass.isEmpty && (Flavor.isPrivate || !server.isEmpty))
    }

    /// Rellena el formulario con los datos del enlace carraca://login
    /// (o, si no hay enlace, con el último servidor usado).
    private func applyPrefill() {
        guard let p = session.prefill else {
            if server.isEmpty { server = UserDefaults.standard.string(forKey: Session.lastServerKey) ?? "" }
            return
        }
        if !p.m3u.isEmpty {
            mode = .m3u
            m3u = p.m3u
        } else {
            mode = .xtream
            server = p.server
            user = p.user
            pass = p.pass
        }
        session.prefill = nil
    }

    private func field(_ title: String, text: Binding<String>, icon: String, keyboard: UIKeyboardType) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 22)
            TextField(title, text: text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))
    }

    private func doLogin() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            if mode == .m3u {
                try await session.loginM3U(m3u)
            } else {
                try await session.login(server: server, user: user, pass: pass)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Pestañas

struct MainTabView: View {
    @EnvironmentObject private var session: Session

    var body: some View {
        TabView {
            LiveView().tabItem { Label("Directo", systemImage: "tv") }
            if !session.isM3U {
                MoviesView().tabItem { Label("Películas", systemImage: "film") }
                SeriesView().tabItem { Label("Series", systemImage: "rectangle.stack.badge.play") }
            }
            if session.resumeEnabled {
                ContinueView().tabItem { Label("Seguir", systemImage: "clock.arrow.circlepath") }
            }
            if session.showsEvents {
                SportsView().tabItem { Label("Eventos", systemImage: "sportscourt") }
            }
        }
    }
}

// MARK: - Ajustes

struct SettingsView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var manage = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let m3u = session.creds?.m3u {
                        LabeledContent("Lista M3U", value: URL(string: m3u)?.host ?? m3u)
                    } else {
                        LabeledContent("Usuario", value: session.creds?.user ?? "-")
                        LabeledContent("Servidor", value: session.creds?.usesDefaultServer == true ? "Carraca" : (session.creds?.server ?? "-"))
                    }
                    if let exp = session.account?.expDate {
                        LabeledContent("Caduca", value: exp.formatted(date: .long, time: .omitted))
                    }
                    if let max = session.account?.maxConnections {
                        LabeledContent("Conexiones", value: String(max))
                    }
                } header: {
                    Text("Cuenta")
                } footer: {
                    if session.remoteResume {
                        Text("\"Seguir viendo\" se sincroniza con el servidor de tu cuenta: lo que empiezas en la tele lo continúas aquí.")
                    }
                }
                if !Flavor.isPrivate {
                    Section("Suscripción") {
                        LabeledContent("Carraca Premium", value: store.isPremium ? "Activa" : "No activa")
                        if let e = store.expiration {
                            LabeledContent(store.willRenew ? "Se renueva" : "Termina",
                                           value: e.formatted(date: .long, time: .omitted))
                        }
                        Button("Gestionar suscripción") { manage = true }
                        Button("Canjear código") { Task { await store.redeemCode() } }
                        Button("Restaurar compras") { Task { await store.restore() } }
                    }
                }
                Section {
                    Button("Recargar listas de canales y películas") {
                        DiskCache.clear()
                        session.reloadToken += 1
                        dismiss()
                    }
                } footer: {
                    Text("Las listas se guardan 12 horas para que la app vaya rápida.")
                }
                Section {
                    Button("Cerrar sesión", role: .destructive) {
                        session.logout()
                        dismiss()
                    }
                }
                Section {
                    LabeledContent("Versión", value: "\(AppConfig.version) (\(AppConfig.build))")
                    Link("Política de privacidad", destination: URL(string: AppConfig.panel + "/ios/privacidad.html")!)
                } footer: {
                    Text("Carraca es un reproductor: no incluye ni vende contenido. Tus datos de acceso se guardan solo en este dispositivo.")
                }
            }
            .manageSubscriptionsSheet(isPresented: $manage)
            .navigationTitle("Ajustes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Cerrar") { dismiss() } }
            }
        }
    }
}

private struct SettingsButton: ViewModifier {
    @State private var show = false
    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { show = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $show) { SettingsView() }
    }
}

extension View {
    func withSettings() -> some View { modifier(SettingsButton()) }
}

// MARK: - Componentes

struct RemoteImage: View {
    let url: String?
    var contentMode: ContentMode = .fill

    var body: some View {
        if let s = url, let u = URL(string: s) {
            AsyncImage(url: u, transaction: Transaction(animation: .easeIn(duration: 0.15))) { phase in
                if let img = phase.image {
                    img.resizable().aspectRatio(contentMode: contentMode)
                } else {
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
    }
}

struct PosterCell: View {
    let title: String
    let image: String?
    var progress: Double? = nil
    var watched = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay { RemoteImage(url: image) }
                .overlay(alignment: .bottom) {
                    if let progress {
                        ProgressView(value: progress).tint(.accentColor).padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if watched { WatchedBadge().padding(5) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(title)
                .font(.caption)
                .lineLimit(2)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct CategoryRow: View {
    let name: String
    let count: Int

    var body: some View {
        HStack {
            Text(name).lineLimit(1)
            Spacer()
            Text("\(count)").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct LoadingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text("Cargando…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark").font(.largeTitle).foregroundStyle(.secondary)
            Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Reintentar", action: retry).buttonStyle(.bordered)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

let posterColumns = [GridItem(.adaptive(minimum: 108, maximum: 170), spacing: 12)]

/// Marca de "ya visto" sobre una carátula.
struct WatchedBadge: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(5)
            .background(Circle().fill(Color.green))
    }
}

/// Etiqueta pequeña (RAW, 4K, 60FPS…) sacada del nombre de la categoría.
struct TagChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(Color.accentColor)
            .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
    }
}

/// Fila horizontal de carátulas (estilo Netflix) con "Ver todo".
struct PosterRail<T: Identifiable & Hashable>: View {
    let title: String
    let tag: String?
    let seeAll: Category?
    let count: Int
    let items: [T]
    let width: CGFloat
    let titleOf: (T) -> String
    let imageOf: (T) -> String?
    let progressOf: (T) -> Double?
    let watchedOf: (T) -> Bool

    init(_ title: String, tag: String? = nil, seeAll: Category? = nil, count: Int = 0, items: [T], width: CGFloat,
         title titleOf: @escaping (T) -> String, image imageOf: @escaping (T) -> String?,
         progress progressOf: @escaping (T) -> Double? = { _ in nil },
         watched watchedOf: @escaping (T) -> Bool = { _ in false }) {
        self.watchedOf = watchedOf
        self.title = title
        self.tag = tag
        self.seeAll = seeAll
        self.count = count
        self.items = items
        self.width = width
        self.titleOf = titleOf
        self.imageOf = imageOf
        self.progressOf = progressOf
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title).font(.title3.bold()).lineLimit(1)
                if let tag { TagChip(text: tag) }
                Spacer(minLength: 8)
                if let seeAll {
                    NavigationLink(value: seeAll) {
                        HStack(spacing: 3) {
                            Text(count > 0 ? "Ver \(count)" : "Ver todo")
                            Image(systemName: "chevron.right")
                        }
                        .font(.subheadline)
                    }
                }
            }
            .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(items) { it in
                        NavigationLink(value: it) {
                            PosterCell(title: titleOf(it), image: imageOf(it), progress: progressOf(it), watched: watchedOf(it))
                                .frame(width: width)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

/// Fila de categoría de directo (vista lista): logo del primer canal + nombre + nº de canales.
struct CategoryListRow: View {
    let name: String
    let tag: String?
    let count: Int
    let logo: String?
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let symbol, logo == nil {
                    Image(systemName: symbol).foregroundStyle(symbol == "star.fill" ? Color.yellow : Color.accentColor)
                } else {
                    RemoteImage(url: logo, contentMode: .fit).padding(3)
                }
            }
            .frame(width: 52, height: 34)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(name).lineLimit(1)
            if let tag { TagChip(text: tag) }
            Spacer(minLength: 6)
            Text("\(count)").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// Tarjeta de categoría de directo: logos de sus primeros canales + nombre + nº de canales.
struct CategoryCard: View {
    let name: String
    let tag: String?
    let count: Int
    let logos: [String]
    var symbol: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { i in
                    Group {
                        if i < logos.count {
                            RemoteImage(url: logos[i], contentMode: .fit).padding(3)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.caption).foregroundStyle(.yellow) }
                Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let tag { TagChip(text: tag) }
            }
            Text("\(count) canales").font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}
