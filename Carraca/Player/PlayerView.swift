import SwiftUI
import AVFoundation
import MediaPlayer
import MobileVLCKit

struct PlayerView: View {
    /// Lo que se está reproduciendo (cambia al pasar al siguiente capítulo).
    @State private var item: PlayItem
    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vlc = VLCController()
    /// Pantalla externa (AirPlay/HDMI): si está activa, el vídeo sale ahí y aquí solo van los controles.
    @ObservedObject private var external = ExternalDisplay.shared
    /// AirPlay con relay: la TV muestra el vídeo y el teléfono no reproduce nada (ver AirPlayRelay.swift).
    @ObservedObject private var cast = AirPlayCast.shared
    /// Último estado de la salida AirPlay (solo se actúa cuando cambia de verdad).
    @State private var routeAirPlay = AirPlayCast.routeIsAirPlay
    /// false al salir del reproductor: no se vuelve a abrir la conexión después.
    @State private var alive = true
    @State private var showControls = true
    @State private var hideWork: DispatchWorkItem?
    @State private var epg: [EPGEntry] = []
    /// Directo: panel con la lista de canales (botón o deslizar desde el borde derecho).
    @State private var showChannels = false
    /// Directo: posición del canal actual dentro de item.channels (para anterior/siguiente).
    @State private var channelIndex: Int?
    /// Canales vistos hace poco (arriba en la lista de canales), calculados al abrirla.
    @State private var recentStreams: [LiveStream] = []
    @State private var zapWork: DispatchWorkItem?
    /// Siguiente capítulo: cuenta atrás al acabar.
    @State private var upNext: PlayItem?
    @State private var countdown = 10
    /// Temporizador de apagado.
    @State private var sleepEnd: Date?
    @State private var sleepAtEnd = false
    /// Gestos: brillo (mitad izquierda) y volumen (derecha) deslizando en vertical; en el centro,
    /// hacia abajo, se cierra. En horizontal, cambiar de canal (directo).
    private enum DragMode { case brightness, volume, close, horizontal }
    @State private var dragMode: DragMode?
    @State private var dragStart: CGFloat = 0
    @State private var closeOffset: CGFloat = 0
    /// Brillo que había al abrir (se devuelve al salir).
    @State private var originalBrightness: CGFloat?
    /// Indicador de brillo / volumen.
    @State private var hud: PlayerHUD?
    @State private var hudWork: DispatchWorkItem?
    /// Candado: la pantalla no responde a toques (para verlo en la cama, con niños…).
    @State private var locked = false
    @State private var showUnlock = false
    @State private var unlockWork: DispatchWorkItem?
    /// Doble toque a un lado: segundos saltados (se acumulan si se repite), para el aviso en pantalla.
    @State private var seekFlash = 0
    @State private var flashWork: DispatchWorkItem?
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    private let second = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(item: PlayItem) {
        _item = State(initialValue: item)
    }

    private var currentChannel: LiveStream? {
        guard let i = channelIndex, item.channels.indices.contains(i) else { return nil }
        return item.channels[i]
    }
    private var title: String { currentChannel?.label.name ?? item.title }
    private var canZap: Bool { item.isLive && item.channels.count > 1 && item.channelURL != nil }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // volumen del sistema (invisible): permite subir/bajar deslizando
            SystemVolumeHost().frame(width: 1, height: 1).opacity(0.02).allowsHitTesting(false)
            VLCVideoView(controller: vlc)
                .ignoresSafeArea()
                .scaleEffect(1 - min(closeOffset, 400) / 1600)
                .offset(y: closeOffset)
            // AVPlayer de la emisión AirPlay: capa oculta (el vídeo sale por la TV)
            CastPlayerHost(player: cast.player)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
            if external.active || cast.phase == .casting {
                ExternalPlaybackNotice(routeName: external.active ? external.routeName : AirPlayCast.routeName)
                    .allowsHitTesting(false)
            }
            // Capa que recibe los toques encima del vídeo (muestra/oculta los controles).
            // Pelis y series: doble toque a la izquierda / derecha = atrasar / adelantar 10 s.
            GeometryReader { geo in
                Color.clear
                    .contentShape(Rectangle())
                    .modifier(DoubleTapSeek(enabled: !item.isLive && !locked) { p in
                        doubleTapSeek(forward: p.x > geo.size.width / 2)
                    })
                    .onTapGesture {
                        if locked { flashUnlock(); return }
                        withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
                        if showControls { scheduleHide() }
                    }
                    .gesture(DragGesture(minimumDistance: 12)
                        .onChanged { v in dragChanged(v, size: geo.size) }
                        .onEnded { v in dragEnded(v, size: geo.size) })
            }
            .ignoresSafeArea()
            if seekFlash != 0 { seekFlashView.transition(.opacity) }
            MomentPlayerLayer()
            if let h = hud {
                hudView(h)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 28)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
            if locked && showUnlock {
                Button {
                    locked = false
                    showUnlock = false
                    showControlsBriefly()
                } label: {
                    Label("Desbloquear", systemImage: "lock.fill")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 30)
                .transition(.opacity)
                .zIndex(3)
            }
            if vlc.buffering && !vlc.failed && upNext == nil && !external.active && cast.phase == .idle {
                ProgressView().controlSize(.large).tint(.white).allowsHitTesting(false)
            }
            if cast.phase != .idle {
                castOverlay
            } else if let next = upNext {
                upNextCard(next)
            } else if vlc.failed {
                failure
            } else if (showControls || external.active) && !showChannels && !locked && dragMode != .close {
                controls.transition(.opacity)
            }
            if showChannels {
                ChannelPanel(channels: item.channels, current: channelIndex, recents: recentStreams,
                             onPick: { i in
                                 withAnimation(.easeInOut(duration: 0.25)) { showChannels = false }
                                 if i != channelIndex { zapTo(i, delay: 0.25) }
                             },
                             onPickStream: { pick($0) },
                             onClose: { withAnimation(.easeInOut(duration: 0.25)) { showChannels = false } })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(2)
            }
        }
        .background(keyboardShortcuts)
        .seasonTint()
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            ThemeStore.shared.paused = true      // la decoración de temporada no se ve: que no gaste
            PlayerPresence.shared.open = true
            UIApplication.shared.isIdleTimerDisabled = true
            setOrientation(.landscape)
            if item.isLive, !item.channels.isEmpty { channelIndex = item.channelIndex }
            // la cuenta solo admite una conexión: si se está descargando algo, se pausa mientras tanto
            if !item.url.isFileURL { Downloads.shared.pauseForPlayback() }
            // antes de arrancar: si ya hay pantalla externa (espejo activo), el vídeo sale ahí
            ExternalDisplay.shared.bind(vlc)
            // si la salida ya es AirPlay, no se abre VLC: directamente la emisión por el relay
            if castPossible, AirPlayCast.routeIsAirPlay {
                startCast(fromMs: item.isLive ? 0 : item.startMs)
            } else {
                vlc.start(url: item.url, startMs: item.startMs, live: item.isLive)
            }
            rememberChannel()
            setUpRemoteCommands()
            scheduleHide()
        }
        .onDisappear {
            report()
            alive = false
            if let b = originalBrightness { UIScreen.main.brightness = b }
            // el último canal se guardó sin avisar; ahora sí, para "Seguir viendo · canal"
            if item.isLive { session.objectWillChange.send() }
            // Ajustes > Descargas > Borrar lo ya visto
            Downloads.shared.removeWatched(session.isWatched(download:))
            ExternalDisplay.shared.unbind(vlc)
            vlc.stop()
            tearDownRemoteCommands()
            // las descargas solo vuelven a abrir conexión cuando la emisión AirPlay ya la ha soltado
            Task { @MainActor in
                await AirPlayCast.shared.stop()
                Downloads.shared.resumeAfterPlayback()
            }
            ThemeStore.shared.paused = false
            PlayerPresence.shared.open = false
            UIApplication.shared.isIdleTimerDisabled = false
            setOrientation(.portrait)
        }
        .onReceive(tick) { _ in
            report()
            updateNowPlaying()
        }
        .onReceive(second) { _ in secondTick() }
        // salida de audio: iPhone <-> AirPlay (solo en cambios reales de la salida)
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
            routeChanged()
        }
        // con pantalla externa (espejo) manda el espejo: la emisión por relay se para
        .onChange(of: external.active) { on in
            if on, cast.phase != .idle { leaveCast() }
        }
        .onChange(of: vlc.ended) { done in
            guard done else { return }
            report(final: true)
            if !sleepAtEnd, PlaybackPrefs.autoNext, let next = item.next?() {
                countdown = 10
                upNext = next
            } else {
                dismiss()
            }
        }
        .onChange(of: vlc.playing) { _ in updateNowPlaying() }
        .onChange(of: vlc.rate) { _ in updateNowPlaying() }
        // botones de volumen del iPhone: el aviso del sistema no sale (por el control invisible), sale el nuestro
        .onReceive(AVAudioSession.sharedInstance().publisher(for: \.outputVolume).dropFirst()) { v in
            if dragMode != .volume { showHUD(volumeIcon(Double(v)), Double(v)) }
        }
        .task { await loadEPG() }
    }

    // MARK: Controles

    private var controls: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.75), .clear, .clear, .black.opacity(0.85)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack {
                HStack(alignment: .top, spacing: 14) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.title3.weight(.semibold))
                            .padding(12)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("Cerrar")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.headline).lineLimit(1)
                        if let s = item.subtitle { Text(s).font(.subheadline).opacity(0.8).lineLimit(1) }
                        if let now = epg.first {
                            Text("Ahora: \(now.title)").font(.subheadline).lineLimit(1)
                            if let a = now.start, let b = now.end {
                                ProgramProgress(entry: GuideEntry(start: a, end: b, title: now.title)).frame(width: 160)
                            }
                        }
                        if epg.count > 1 { Text("Después: \(epg[1].title)").font(.caption).opacity(0.75).lineLimit(1) }
                        if !item.isLive && vlc.rate != 1 {
                            Label("Velocidad \(rateText(vlc.rate))", systemImage: "speedometer").font(.caption).opacity(0.8)
                        }
                        if let end = sleepEnd {
                            Label("Se apaga a las \(end.formatted(date: .omitted, time: .shortened))", systemImage: "moon.zzz")
                                .font(.caption).opacity(0.8)
                        } else if sleepAtEnd {
                            Label("Se apaga al terminar", systemImage: "moon.zzz").font(.caption).opacity(0.8)
                        }
                    }
                    Spacer()
                    Button {
                        locked = true
                        hideWork?.cancel()
                        withAnimation(.easeInOut(duration: 0.2)) { showControls = false }
                        flashUnlock()
                    } label: {
                        Image(systemName: "lock.open")
                            .font(.title3)
                            .frame(width: 22, height: 22)
                            .padding(12)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("Bloquear pantalla")
                    if canZap {
                        Button { openChannels() } label: {
                            Image(systemName: "list.bullet")
                                .font(.title3)
                                .frame(width: 22, height: 22)
                                .padding(12)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .accessibilityLabel("Lista de canales")
                    }
                    AirPlayButton()
                        .frame(width: 44, height: 44)
                    optionsMenu
                    if !vlc.audioTracks.isEmpty || !vlc.subtitleTracks.isEmpty { tracksMenu }
                }
                .padding()

                Spacer()

                HStack(spacing: 52) {
                    if !item.isLive {
                        Button { jumpBy(-10); scheduleHide() } label: { Image(systemName: "gobackward.10").font(.system(size: 34)) }
                            .accessibilityLabel("Atrasar 10 segundos")
                    } else if canZap {
                        Button { zap(-1) } label: { Image(systemName: "backward.end.fill").font(.system(size: 32)) }
                            .accessibilityLabel("Canal anterior")
                    }
                    Button { togglePlayback(); scheduleHide() } label: {
                        Image(systemName: vlc.playing ? "pause.fill" : "play.fill").font(.system(size: 46))
                    }
                    .accessibilityLabel(vlc.playing ? "Pausa" : "Reproducir")
                    if !item.isLive {
                        Button { jumpBy(30); scheduleHide() } label: { Image(systemName: "goforward.30").font(.system(size: 34)) }
                            .accessibilityLabel("Adelantar 30 segundos")
                    } else if canZap {
                        Button { zap(1) } label: { Image(systemName: "forward.end.fill").font(.system(size: 32)) }
                            .accessibilityLabel("Canal siguiente")
                    }
                }

                Spacer()

                if item.isLive {
                    HStack {
                        Text("● EN DIRECTO")
                            .font(.caption.bold())
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.red.opacity(0.85), in: Capsule())
                        Spacer()
                    }
                    .padding()
                } else {
                    SeekArea(clock: vlc.clock, hasNext: item.next != nil,
                             onSeek: { f in vlc.seek(toFraction: f) },
                             onNext: { playNextNow() },
                             onEditing: { hideWork?.cancel() },
                             onDone: { scheduleHide() })
                }
            }
            .foregroundStyle(.white)
        }
    }

    private func openChannels() {
        guard canZap else { return }
        recentStreams = recents()
        hideWork?.cancel()
        withAnimation(.easeInOut(duration: 0.25)) {
            showControls = false
            showChannels = true
        }
    }

    private var tracksMenu: some View {
        Menu {
            if !vlc.audioTracks.isEmpty {
                Section("Audio") {
                    ForEach(vlc.audioTracks) { t in
                        Button { vlc.setAudio(t.id) } label: {
                            if t.id == vlc.currentAudio { Label(t.name, systemImage: "checkmark") } else { Text(t.name) }
                        }
                    }
                }
            }
            if !vlc.subtitleTracks.isEmpty {
                Section("Subtítulos") {
                    ForEach(vlc.subtitleTracks) { t in
                        Button { vlc.setSubtitle(t.id) } label: {
                            if t.id == vlc.currentSubtitle { Label(t.name, systemImage: "checkmark") } else { Text(t.name) }
                        }
                    }
                }
            }
            Section("Sincronizar") {
                Menu("Subtítulos (\(delayText(vlc.subtitleDelayMs)))") {
                    Button("Adelantar 0,5 s") { vlc.subtitleDelayMs -= 500 }
                    Button("Retrasar 0,5 s") { vlc.subtitleDelayMs += 500 }
                    Button("Restablecer") { vlc.subtitleDelayMs = 0 }
                }
                Menu("Audio (\(delayText(vlc.audioDelayMs)))") {
                    Button("Adelantar 0,1 s") { vlc.audioDelayMs -= 100 }
                    Button("Retrasar 0,1 s") { vlc.audioDelayMs += 100 }
                    Button("Restablecer") { vlc.audioDelayMs = 0 }
                }
            }
        } label: {
            Image(systemName: "captions.bubble")
                .font(.title3)
                .padding(12)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel("Audio y subtítulos")
    }

    private func rateText(_ r: Float) -> String {
        r == 1 ? "normal" : (String(format: "%g", r).replacingOccurrences(of: ".", with: ",") + "×")
    }

    /// Formato de imagen, velocidad y temporizador de apagado.
    private var optionsMenu: some View {
        Menu {
            if !item.isLive {
                Section("Velocidad") {
                    ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2], id: \.self) { r in
                        Button { vlc.rate = r } label: {
                            let t = r == 1 ? "Normal" : rateText(r)
                            if vlc.rate == r { Label(t, systemImage: "checkmark") } else { Text(t) }
                        }
                    }
                }
            }
            Section("Imagen") {
                ForEach(VLCController.AspectMode.allCases, id: \.self) { m in
                    Button { vlc.aspect = m } label: {
                        if vlc.aspect == m { Label(m.title, systemImage: "checkmark") } else { Text(m.title) }
                    }
                }
            }
            Section("Apagar") {
                ForEach([15, 30, 60, 90], id: \.self) { min in
                    Button("Dentro de \(min) min") { sleepEnd = Date().addingTimeInterval(Double(min) * 60); sleepAtEnd = false }
                }
                if !item.isLive {
                    Button("Al terminar este capítulo o peli") { sleepAtEnd = true; sleepEnd = nil }
                }
                if sleepEnd != nil || sleepAtEnd {
                    Button("Cancelar temporizador", role: .destructive) { sleepEnd = nil; sleepAtEnd = false }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.title3)
                .frame(width: 22, height: 22)
                .padding(12)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel("Opciones")
    }

    private func delayText(_ ms: Int) -> String {
        ms == 0 ? "0 s" : String(format: "%+.1f s", Double(ms) / 1000).replacingOccurrences(of: ".", with: ",")
    }

    private func upNextCard(_ next: PlayItem) -> some View {
        VStack(spacing: 14) {
            Text("Siguiente capítulo").font(.subheadline).opacity(0.8)
            Text(next.subtitle ?? next.title).font(.headline).multilineTextAlignment(.center).lineLimit(2)
            Text("Empieza en \(countdown) s").font(.title2.monospacedDigit().bold())
            HStack(spacing: 16) {
                Button("Ver ahora") { playNextNow() }.buttonStyle(.borderedProminent)
                Button("Cerrar") { upNext = nil; dismiss() }.buttonStyle(.bordered)
            }
        }
        .foregroundStyle(.white)
        .padding(28)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding()
    }

    /// Qué ha pasado, en cristiano (en vez de un "no se ha podido reproducir" para todo).
    private var failText: (icon: String, title: String, detail: String) {
        if let exp = session.account?.expDate, exp < Date() {
            return ("calendar.badge.exclamationmark", "Tu cuenta ha caducado",
                    "Renueva la suscripción con tu proveedor para seguir viendo.")
        }
        switch vlc.failReason {
        case .busy:
            return ("person.2.slash", "La cuenta se está usando en otro sitio",
                    "Tu cuenta solo admite una conexión y ahora mismo está abierta en otro dispositivo (tele, móvil…). Ciérralo y pulsa Reintentar.")
        case .blocked:
            return ("hand.raised", "El proveedor ha cortado la conexión",
                    "Suele pasar tras cambiar muchos canales seguidos o si la cuenta está en uso. Espera unos minutos sin abrir nada y vuelve a probar.")
        case .missing:
            return ("film.stack", "No está disponible",
                    "El proveedor lo ha retirado o no lo tiene ahora mismo.")
        case .server:
            return ("server.rack", "El servidor del proveedor está fallando",
                    "No es cosa de tu conexión. Prueba en unos minutos.")
        case .offline:
            return ("wifi.slash", "Sin conexión a internet", "Comprueba el Wi-Fi o los datos móviles.")
        case .file:
            return ("exclamationmark.triangle", "No se puede abrir la descarga",
                    "Puede que el archivo esté incompleto. Bórralo en Descargas y vuelve a descargarlo.")
        case .checking, .generic:
            return ("exclamationmark.triangle", "No se ha podido reproducir",
                    "Puede que no esté disponible ahora mismo. Prueba en unos minutos.")
        }
    }

    private var failure: some View {
        let f = failText
        return VStack(spacing: 14) {
            Image(systemName: f.icon).font(.largeTitle)
            Text(f.title).font(.headline).multilineTextAlignment(.center)
            if vlc.failReason == .checking {
                ProgressView().tint(.white)
            } else {
                Text(f.detail)
                    .font(.subheadline).multilineTextAlignment(.center).opacity(0.8)
                    .frame(maxWidth: 460)
            }
            HStack(spacing: 16) {
                Button("Reintentar") { vlc.restart() }.buttonStyle(.borderedProminent)
                Button("Cerrar") { dismiss() }.buttonStyle(.bordered)
            }
        }
        .foregroundStyle(.white)
        .padding(30)
    }

    /// Aviso "−10 s / +20 s" al lado donde se ha tocado.
    private var seekFlashView: some View {
        HStack {
            if seekFlash > 0 { Spacer() }
            VStack(spacing: 6) {
                Image(systemName: seekFlash > 0 ? "goforward" : "gobackward").font(.system(size: 30))
                Text("\(seekFlash > 0 ? "+" : "−")\(abs(seekFlash)) s").font(.headline.monospacedDigit())
            }
            .foregroundStyle(.white)
            .frame(width: 110, height: 110)
            .background(.ultraThinMaterial, in: Circle())
            .padding(.horizontal, 70)
            if seekFlash < 0 { Spacer() }
        }
        .allowsHitTesting(false)
    }

    /// Teclado (iPad con teclado, Mac): espacio = pausa, ← → = 10 s (en directo, canal),
    /// ↑ ↓ = 1 min (en directo, canal), Esc = cerrar.
    private var keyboardShortcuts: some View {
        ZStack {
            Button("Pausa") { togglePlayback(); showControlsBriefly() }
                .keyboardShortcut(.space, modifiers: [])
            Button("Atrás") { item.isLive ? zap(-1) : doubleTapSeek(forward: false) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("Adelante") { item.isLive ? zap(1) : doubleTapSeek(forward: true) }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button("Subir") { if item.isLive { zap(-1) } else { jumpBy(60); showControlsBriefly() } }
                .keyboardShortcut(.upArrow, modifiers: [])
            Button("Bajar") { if item.isLive { zap(1) } else { jumpBy(-60); showControlsBriefly() } }
                .keyboardShortcut(.downArrow, modifiers: [])
            Button("Cerrar") { dismiss() }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func showControlsBriefly() {
        withAnimation(.easeInOut(duration: 0.2)) { showControls = true }
        scheduleHide()
    }

    // MARK: Gestos (brillo, volumen, cerrar, cambiar de canal) y candado

    private func dragChanged(_ v: DragGesture.Value, size: CGSize) {
        guard !locked, !showChannels, upNext == nil else { return }
        let dx = v.translation.width, dy = v.translation.height
        if dragMode == nil {
            guard max(abs(dx), abs(dy)) > 12 else { return }
            if abs(dy) > abs(dx) {
                let third = size.width / 3
                if v.startLocation.x < third {
                    dragMode = .brightness
                    dragStart = UIScreen.main.brightness
                    if originalBrightness == nil { originalBrightness = dragStart }
                } else if v.startLocation.x > third * 2 {
                    dragMode = .volume
                    dragStart = CGFloat(AVAudioSession.sharedInstance().outputVolume)
                } else {
                    dragMode = .close
                }
            } else {
                dragMode = .horizontal
            }
        }
        let span = max(200, size.height * 0.75)
        guard let mode = dragMode else { return }
        switch mode {
        case .brightness:
            let b = min(1, max(0, dragStart - dy / span))
            UIScreen.main.brightness = b
            showHUD(b < 0.35 ? "sun.min.fill" : "sun.max.fill", Double(b))
        case .volume:
            let vol = min(1, max(0, dragStart - dy / span))
            SystemVolume.set(Float(vol))
            showHUD(volumeIcon(Double(vol)), Double(vol))
        case .close:
            closeOffset = max(0, dy)
        default:
            break
        }
    }

    private func dragEnded(_ v: DragGesture.Value, size: CGSize) {
        defer { dragMode = nil }
        guard !locked else { return }
        let dx = v.translation.width, dy = v.translation.height
        guard let mode = dragMode else { return }
        switch mode {
        case .close:
            if dy > 140 || v.predictedEndTranslation.height > 320 {
                dismiss()
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { closeOffset = 0 }
            }
        case .horizontal:
            // Directo: deslizar cambia de canal; desde el borde derecho hacia dentro, la lista de canales.
            guard canZap, abs(dx) > abs(dy) * 1.5 else { return }
            if v.startLocation.x > size.width - 70, dx < -50 {
                openChannels()
                return
            }
            guard abs(dx) > 80 else { return }
            zap(dx < 0 ? 1 : -1)
        default:
            break
        }
    }

    private func volumeIcon(_ v: Double) -> String {
        v <= 0.001 ? "speaker.slash.fill" : v < 0.34 ? "speaker.wave.1.fill" : v < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }

    private func showHUD(_ icon: String, _ value: Double) {
        if hud == nil {
            withAnimation(.easeOut(duration: 0.15)) { hud = PlayerHUD(icon: icon, value: value) }
        } else {
            hud = PlayerHUD(icon: icon, value: value)
        }
        hudWork?.cancel()
        let w = DispatchWorkItem { withAnimation(.easeIn(duration: 0.25)) { hud = nil } }
        hudWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: w)
    }

    private func hudView(_ h: PlayerHUD) -> some View {
        HStack(spacing: 12) {
            Image(systemName: h.icon).font(.headline).frame(width: 24)
            ProgressView(value: h.value).tint(.white).frame(width: 140)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
    }

    /// Con el candado puesto, un toque enseña el botón de desbloquear un momento.
    private func flashUnlock() {
        withAnimation(.easeInOut(duration: 0.2)) { showUnlock = true }
        unlockWork?.cancel()
        let w = DispatchWorkItem { withAnimation(.easeInOut(duration: 0.3)) { showUnlock = false } }
        unlockWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: w)
    }

    // MARK: Lógica

    private func doubleTapSeek(forward: Bool) {
        let step = forward ? 10 : -10
        if (seekFlash > 0) != forward { seekFlash = 0 }
        withAnimation(.easeOut(duration: 0.12)) { seekFlash += step }
        jumpBy(step)
        flashWork?.cancel()
        let w = DispatchWorkItem { withAnimation(.easeIn(duration: 0.25)) { seekFlash = 0 } }
        flashWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: w)
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { withAnimation(.easeInOut(duration: 0.3)) { showControls = false } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    private func report(final: Bool = false) {
        guard !item.isLive else { return }
        let len = vlc.lengthMs
        // con AirPlay, la posición es la de la emisión (VLC está parado)
        let t = cast.phase == .idle ? vlc.timeMs : Int(cast.positionSec * 1000)
        session.report(item, timeMs: final ? len : t, lengthMs: len)
    }

    private func secondTick() {
        if let end = sleepEnd, Date() >= end {
            sleepEnd = nil
            dismiss()
            return
        }
        guard upNext != nil else { return }
        countdown -= 1
        if countdown <= 0 { playNextNow() }
    }

    /// Pasa al siguiente capítulo sin salir del reproductor.
    private func playNextNow() {
        // con AirPlay no se cambia de capítulo desde aquí (la emisión va por el relay)
        guard cast.phase == .idle else { return }
        let next = upNext ?? item.next?()
        upNext = nil
        guard let next else { dismiss(); return }
        if !vlc.ended { report() }
        item = next
        epg = []
        vlc.start(url: next.url, startMs: next.startMs, live: next.isLive)
        updateNowPlaying()
        showControls = true
        scheduleHide()
    }

    /// iPhone: el vídeo se abre en horizontal y al salir se vuelve a vertical (en iPad no se fuerza).
    private func setOrientation(_ mask: UIInterfaceOrientationMask) {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        // 1) Cambiar lo que la app permite (si no, iOS ignora la petición de giro).
        AppDelegate.orientationLock = mask
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                window.rootViewController?.presentedViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            // 2) Pedir el giro.
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        }
        // 3) Al volver a vertical, en cuanto gire se vuelve a permitir rotar libremente en las listas.
        if mask == .portrait {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                AppDelegate.orientationLock = .allButUpsideDown
            }
        }
    }

    /// Canal anterior (-1) o siguiente (+1). El nombre cambia al momento, pero el canal solo se abre
    /// cuando se deja de cambiar (0,6 s): pasar canales rápido no dispara una ráfaga de conexiones
    /// (el proveedor banea la IP por eso).
    private func zap(_ step: Int) {
        guard canZap, let i = channelIndex else { return }
        let n = item.channels.count
        zapTo(((i + step) % n + n) % n, delay: 0.6)
    }

    /// Canales recientes que se pueden abrir desde aquí (sin el que se está viendo).
    private func recents() -> [LiveStream] {
        let pool = item.allChannels.isEmpty ? item.channels : item.allChannels
        var byID: [Int: LiveStream] = [:]
        for c in pool where byID[c.id] == nil { byID[c.id] = c }
        let now = currentChannel?.id
        return session.recentChannelIDs.filter { $0 != now }.compactMap { byID[$0] }
    }

    /// Canal reciente: si está en la lista actual se cambia ahí; si es de otra categoría,
    /// la lista pasa a ser la de su categoría (anterior / siguiente siguen teniendo sentido).
    private func pick(_ ch: LiveStream) {
        withAnimation(.easeInOut(duration: 0.25)) { showChannels = false }
        if let i = item.channels.firstIndex(of: ch) {
            if i != channelIndex { zapTo(i, delay: 0.25) }
            return
        }
        let same = item.allChannels.filter { $0.categoryId == ch.categoryId }
        let list = same.contains(ch) ? same : [ch]
        item.channels = list
        zapTo(list.firstIndex(of: ch) ?? 0, delay: 0.25)
    }

    /// Cambia al canal `next` de la lista (desde el panel, casi sin espera).
    private func zapTo(_ next: Int, delay: Double) {
        guard item.isLive, let urlFor = item.channelURL, item.channels.indices.contains(next) else { return }
        channelIndex = next
        epg = []
        showControls = true
        scheduleHide()
        zapWork?.cancel()
        let channel = item.channels[next]
        let work = DispatchWorkItem {
            if cast.phase != .idle {
                if let src = castSource(for: channel) { cast.zap(to: src) }
            } else {
                vlc.start(url: urlFor(channel), startMs: 0, live: true)
            }
            rememberChannel()
            updateNowPlaying()
            Task { await loadEPG() }
        }
        zapWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Sin avisar a las pantallas de detrás (no se repintan con cada cambio de canal).
    private func rememberChannel() {
        guard item.isLive else { return }
        if let c = currentChannel { session.storeLastChannel(c.id) } else if let id = item.liveStreamId { session.storeLastChannel(id) }
    }

    @MainActor
    private func loadEPG() async {
        guard item.isLive else { return }
        // Guía del panel (una sola descarga para todos los canales) si la hay.
        if let c = currentChannel, session.guideEnabled {
            await session.refreshGuide()
            let g = GuideStore.shared.nowNext(c)
            if !g.isEmpty {
                epg = g.map { EPGEntry(title: $0.title, start: $0.start, end: $0.end) }
                return
            }
        }
        guard let api = session.api else { return }
        // Solo canales Xtream tienen guía (los M3U no traen stream_id del servidor).
        let id = currentChannel.map { $0.directURL == nil ? $0.id : nil } ?? item.liveStreamId
        guard let id else { return }
        epg = (try? await api.shortEPG(id)) ?? []
    }

    // MARK: AirPlay con relay (la TV muestra el vídeo; el teléfono no reproduce)

    /// Lo que se emite ahora: en directo, el canal actual; en VOD, la peli o capítulo.
    private var currentCast: CastSource? {
        if item.isLive, let c = currentChannel { return castSource(for: c) }
        return item.cast
    }

    /// Canal de directo emitible (solo Xtream: los M3U tienen URL directa).
    private func castSource(for c: LiveStream) -> CastSource? {
        c.directURL == nil ? CastSource(kind: .live, id: c.id, ext: nil) : nil
    }

    /// Se puede emitir: cuenta del servidor Carraca, hay fuente y no hay pantalla con espejo.
    private var castPossible: Bool {
        session.isCarracaServer && session.creds != nil && currentCast != nil && !external.active
    }

    /// La URL que VLC usaría para lo que se ve ahora (al volver al iPhone).
    private var vlcURL: URL {
        if item.isLive, let c = currentChannel, let f = item.channelURL { return f(c) }
        return item.url
    }

    private func startCast(fromMs: Int) {
        guard castPossible, let src = currentCast, let c = session.creds else { return }
        // VLC se para antes: el servidor necesita su conexión libre (la espera la hace AirPlayCast)
        vlc.suspend()
        cast.begin(src, user: c.user, pass: c.pass, fromSec: Double(max(0, fromMs)) / 1000, wait: 2)
    }

    /// Cambio de salida de audio: iPhone -> AirPlay arranca la emisión; AirPlay -> iPhone vuelve a VLC.
    /// Un fallo deja el aviso y no vuelve a intentar solo: solo cambia con el siguiente cambio de salida.
    private func routeChanged() {
        let nowAirPlay = AirPlayCast.routeIsAirPlay
        guard nowAirPlay != routeAirPlay else { return }
        routeAirPlay = nowAirPlay
        guard alive else { return }
        if nowAirPlay {
            guard cast.phase == .idle, castPossible else { return }
            startCast(fromMs: item.isLive ? 0 : (vlc.timeMs > 0 ? vlc.timeMs : item.startMs))
        } else if cast.phase != .idle {
            leaveCast()
        }
    }

    /// Para la emisión y vuelve a VLC en el teléfono, desde donde se quedó.
    private func leaveCast() {
        let live = item.isLive
        let ms = Int(cast.positionSec * 1000)
        let wasPaused = !cast.playing
        Task { @MainActor in
            await AirPlayCast.shared.stop()
            // dar tiempo a que el proveedor suelte la conexión antes de abrir VLC
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard alive else { return }
            vlc.resume()
            vlc.start(url: vlcURL, startMs: live ? 0 : ms, live: live)
            if wasPaused { vlc.pause() }
        }
    }

    private func togglePlayback() {
        if cast.phase == .casting { cast.togglePlay() } else { vlc.toggle() }
    }

    private func setPlaying(_ on: Bool) {
        if cast.phase == .casting { cast.setPlaying(on) } else if on { vlc.play() } else { vlc.pause() }
    }

    /// Salto relativo: en VOD con AirPlay es un arranque nuevo desde esa posición.
    private func jumpBy(_ seconds: Int) {
        if cast.phase == .casting {
            if !item.isLive { cast.jump(by: Double(seconds)) }
            return
        }
        vlc.jump(Int32(seconds))
    }

    /// Mientras se emite: controles propios (el teléfono no reproduce nada).
    private var castOverlay: some View {
        VStack {
            HStack(alignment: .top, spacing: 14) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.title3.weight(.semibold))
                        .padding(12)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Cerrar")
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).lineLimit(1)
                    if let s = item.subtitle { Text(s).font(.subheadline).opacity(0.8).lineLimit(1) }
                }
                Spacer()
                AirPlayButton()
                    .frame(width: 44, height: 44)
            }
            .padding()

            Spacer()

            switch cast.phase {
            case .preparing:
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large).tint(.white)
                    Text("Preparando emisión…").font(.headline)
                }
            case .casting:
                castTransport
            case .failed(let message):
                VStack(spacing: 14) {
                    Image(systemName: "airplayvideo").font(.largeTitle)
                    Text(message).font(.headline).multilineTextAlignment(.center)
                    HStack(spacing: 16) {
                        Button("Reintentar") { cast.retry() }.buttonStyle(.borderedProminent)
                        Button("Reproducir aquí") { leaveCast() }.buttonStyle(.bordered)
                    }
                }
                .padding(24)
            case .idle:
                EmptyView()
            }

            Spacer()
        }
        .foregroundStyle(.white)
    }

    private var castTransport: some View {
        VStack(spacing: 22) {
            HStack(spacing: 52) {
                if !item.isLive {
                    Button { jumpBy(-10) } label: { Image(systemName: "gobackward.10").font(.system(size: 34)) }
                        .accessibilityLabel("Atrasar 10 segundos")
                } else if canZap {
                    Button { zap(-1) } label: { Image(systemName: "backward.end.fill").font(.system(size: 32)) }
                        .accessibilityLabel("Canal anterior")
                }
                Button { togglePlayback() } label: {
                    Image(systemName: cast.playing ? "pause.fill" : "play.fill").font(.system(size: 46))
                }
                .accessibilityLabel(cast.playing ? "Pausa" : "Reproducir")
                if !item.isLive {
                    Button { jumpBy(10) } label: { Image(systemName: "goforward.10").font(.system(size: 34)) }
                        .accessibilityLabel("Adelantar 10 segundos")
                } else if canZap {
                    Button { zap(1) } label: { Image(systemName: "forward.end.fill").font(.system(size: 32)) }
                        .accessibilityLabel("Canal siguiente")
                }
            }
            Button { leaveCast() } label: {
                Label("Volver al iPhone", systemImage: "iphone")
            }
            .buttonStyle(.bordered)
            if !cast.videoOnTV {
                Text("El vídeo aún no llega a la TV. Si no aparece, elige la TV otra vez en el botón de AirPlay.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .opacity(0.8)
                    .padding(.horizontal, 30)
            }
            Text("Para que el sonido salga del iPhone, elígelo en el botón de AirPlay.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .opacity(0.7)
                .padding(.horizontal, 30)
        }
    }

    // MARK: Pantalla de bloqueo / Centro de control

    private func setUpRemoteCommands() {
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.addTarget { _ in setPlaying(true); return .success }
        cc.pauseCommand.addTarget { _ in setPlaying(false); return .success }
        cc.togglePlayPauseCommand.addTarget { _ in togglePlayback(); return .success }
        if item.isLive {
            cc.nextTrackCommand.addTarget { _ in zap(1); return .success }
            cc.previousTrackCommand.addTarget { _ in zap(-1); return .success }
        } else {
            cc.skipForwardCommand.preferredIntervals = [30]
            cc.skipBackwardCommand.preferredIntervals = [10]
            cc.skipForwardCommand.addTarget { _ in jumpBy(30); return .success }
            cc.skipBackwardCommand.addTarget { _ in jumpBy(-10); return .success }
        }
        updateNowPlaying()
    }

    private func tearDownRemoteCommands() {
        let cc = MPRemoteCommandCenter.shared()
        for c in [cc.playCommand, cc.pauseCommand, cc.togglePlayPauseCommand, cc.nextTrackCommand,
                  cc.previousTrackCommand, cc.skipForwardCommand, cc.skipBackwardCommand] {
            c.removeTarget(nil)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func updateNowPlaying() {
        var info: [String: Any] = [MPMediaItemPropertyTitle: title,
                                   MPNowPlayingInfoPropertyPlaybackRate: vlc.playing ? Double(vlc.rate) : 0.0,
                                   MPNowPlayingInfoPropertyIsLiveStream: item.isLive]
        if let s = item.subtitle { info[MPMediaItemPropertyArtist] = s }
        if !item.isLive, vlc.lengthMs > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = Double(vlc.lengthMs) / 1000
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(vlc.timeMs) / 1000
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

/// Doble toque solo donde tiene sentido (en directo no hay nada que adelantar
/// y así el toque normal no espera a ver si viene otro).
private struct DoubleTapSeek: ViewModifier {
    let enabled: Bool
    let action: (CGPoint) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.onTapGesture(count: 2, coordinateSpace: .local, perform: action)
        } else {
            content
        }
    }
}

/// Barra de progreso (pelis y series): es lo único que se repinta con el tiempo del vídeo.
private struct SeekArea: View {
    @ObservedObject var clock: PlaybackClock
    let hasNext: Bool
    let onSeek: (Double) -> Void
    let onNext: () -> Void
    let onEditing: () -> Void
    let onDone: () -> Void
    @State private var scrub: Double?

    private var fraction: Double {
        clock.lengthMs > 0 ? Double(clock.timeMs) / Double(clock.lengthMs) : 0
    }

    var body: some View {
        if clock.lengthMs > 0 {
            let remaining = max(0, clock.lengthMs - clock.timeMs)
            VStack(alignment: .trailing, spacing: 8) {
                // En los créditos: pasar ya al siguiente capítulo.
                if hasNext, remaining < 90_000, remaining > 0 {
                    Button(action: onNext) {
                        Label("Siguiente capítulo", systemImage: "forward.end.fill")
                            .font(.subheadline.bold())
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                }
                VStack(spacing: 4) {
                    Slider(value: Binding(get: { scrub ?? fraction }, set: { scrub = $0 }), in: 0...1, onEditingChanged: { editing in
                        onEditing()
                        if !editing, let f = scrub {
                            onSeek(f)
                            scrub = nil
                            onDone()
                        }
                    })
                    .accessibilityLabel("Posición")
                    HStack {
                        Text(timeText(scrub.map { Int($0 * Double(clock.lengthMs)) } ?? clock.timeMs))
                        Spacer()
                        Text(timeText(clock.lengthMs))
                    }
                    .font(.caption.monospacedDigit())
                }
            }
            .padding(.horizontal).padding(.bottom, 14)
        }
    }
}

private struct PlayerHUD: Equatable {
    let icon: String
    let value: Double
}
