import SwiftUI

// MARK: - Ajustes

struct SettingsView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var manage = false
    @AppStorage(PlaybackPrefs.audioKey) private var prefAudio = ""
    @AppStorage(PlaybackPrefs.subsKey) private var prefSubs = ""
    @AppStorage(PlaybackPrefs.autoNextKey) private var prefAutoNext = true
    @AppStorage(DownloadPrefs.wifiOnlyKey) private var wifiOnly = true
    @AppStorage(DownloadPrefs.autoDeleteKey) private var autoDelete = false
    @AppStorage(ThemeStore.decorKey) private var decor = true
    @ObservedObject private var theme = ThemeStore.shared

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
                if !Flavor.isPrivate && Store.paywallEnabled {
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
                    Picker("Idioma de audio", selection: $prefAudio) {
                        Text("El que venga").tag("")
                        Text("Castellano").tag("castellano")
                        Text("Latino").tag("latino")
                        Text("Inglés").tag("ingles")
                    }
                    Picker("Subtítulos", selection: $prefSubs) {
                        Text("Como vengan").tag("")
                        Text("Desactivados").tag("off")
                        Text("Castellano").tag("castellano")
                        Text("Inglés").tag("ingles")
                        Text("Solo forzados").tag("forzados")
                    }
                    Toggle("Siguiente capítulo automático", isOn: $prefAutoNext)
                } header: {
                    Text("Reproducción")
                } footer: {
                    Text("Si el vídeo trae ese idioma o subtítulo, se pone solo al empezar.")
                }
                Section {
                    Toggle("Descargar solo con Wi-Fi", isOn: $wifiOnly)
                        .onChange(of: wifiOnly) { _ in Downloads.shared.networkPolicyChanged() }
                    Toggle("Borrar lo ya visto", isOn: $autoDelete)
                        .onChange(of: autoDelete) { on in
                            if on { Downloads.shared.removeWatched(session.isWatched(download:)) }
                        }
                } header: {
                    Text("Descargas")
                } footer: {
                    Text("Con \"solo Wi-Fi\" no se gastan datos móviles: la descarga espera a que haya Wi-Fi. \"Borrar lo ya visto\" libera espacio en cuanto terminas una peli o un capítulo descargado.")
                }
                Section {
                    if let t = theme.current {
                        LabeledContent("Tema de temporada", value: "\(t.emoji) \(t.name)")
                    }
                    Toggle("Decoración de temporada", isOn: $decor)
                } header: {
                    Text("Apariencia")
                } footer: {
                    Text("Carraca se viste para Navidad, Halloween, Carnaval y cada estación: color, nieve u hojas cayendo y una fila especial de pelis. Quita la decoración si prefieres la pantalla limpia.")
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
            .seasonTint()
            .navigationTitle("Ajustes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Cerrar") { dismiss() } }
            }
        }
    }
}
