import SwiftUI

// MARK: - Login

struct LoginView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case xtream = "Servidor", m3u = "Lista M3U"
        var id: String { rawValue }
    }

    @EnvironmentObject private var session: Session
    @ObservedObject private var theme = ThemeStore.shared
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
                Text("Carraca" + (theme.current.map { " " + $0.emoji } ?? "")).font(.largeTitle.bold())

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
