import SwiftUI
import AVFoundation

@main
struct CarracaApp: App {
    @StateObject private var session = Session()

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 400 << 20)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var session: Session

    var body: some View {
        Group {
            if session.api == nil { LoginView() } else { MainTabView() }
        }
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
    @EnvironmentObject private var session: Session
    @State private var server = ""
    @State private var user = ""
    @State private var pass = ""
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

                VStack(alignment: .leading, spacing: 12) {
                    field("Servidor (opcional)", text: $server, icon: "server.rack", keyboard: .URL)
                    Text("Déjalo vacío para usar el servidor Carraca.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                    field("Usuario", text: $user, icon: "person", keyboard: .asciiCapable)
                    HStack {
                        Image(systemName: "lock").foregroundStyle(.secondary).frame(width: 22)
                        SecureField("Contraseña", text: $pass)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))
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
                .disabled(busy || user.isEmpty || pass.isEmpty)
            }
            .padding(24)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .background(Color("LaunchBg").ignoresSafeArea())
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
            try await session.login(server: server, user: user, pass: pass)
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
            MoviesView().tabItem { Label("Películas", systemImage: "film") }
            SeriesView().tabItem { Label("Series", systemImage: "rectangle.stack.badge.play") }
            if session.resumeEnabled {
                ContinueView().tabItem { Label("Seguir", systemImage: "clock.arrow.circlepath") }
            }
            SportsView().tabItem { Label("Deportes", systemImage: "sportscourt") }
        }
    }
}

// MARK: - Ajustes

struct SettingsView: View {
    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var cleared = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Cuenta") {
                    LabeledContent("Usuario", value: session.creds?.user ?? "-")
                    LabeledContent("Servidor", value: session.creds?.usesDefaultServer == true ? "Carraca" : (session.creds?.server ?? "-"))
                    if let exp = session.account?.expDate {
                        LabeledContent("Caduca", value: exp.formatted(date: .long, time: .omitted))
                    }
                    if let max = session.account?.maxConnections {
                        LabeledContent("Conexiones", value: String(max))
                    }
                }
                Section {
                    Button(cleared ? "Listas borradas: se recargan al entrar" : "Recargar listas de canales y películas") {
                        DiskCache.clear()
                        cleared = true
                    }
                    .disabled(cleared)
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
                }
            }
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
