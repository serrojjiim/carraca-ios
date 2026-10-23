import SwiftUI
import MediaPlayer
import MobileVLCKit

struct Track: Identifiable, Hashable {
    let id: Int32
    let name: String
}

/// Envoltorio del motor VLC (reproduce TS, MKV, AVI…).
final class VLCController: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    let player = VLCMediaPlayer()

    @Published var playing = false
    @Published var buffering = true
    @Published var timeMs = 0
    @Published var lengthMs = 0
    @Published var failed = false
    @Published var ended = false

    /// Formato de imagen.
    enum AspectMode: String, CaseIterable {
        case fit, fill, wide, classic
        var title: String {
            switch self {
            case .fit: return "Ajustar (original)"
            case .fill: return "Llenar la pantalla"
            case .wide: return "16:9"
            case .classic: return "4:3"
            }
        }
    }
    @Published var aspect = AspectMode.fit { didSet { applyAspect() } }
    /// Sincronización (ms; positivo = más tarde).
    @Published var subtitleDelayMs = 0 { didSet { player.currentVideoSubTitleDelay = subtitleDelayMs * 1000 } }
    @Published var audioDelayMs = 0 { didSet { player.currentAudioPlaybackDelay = audioDelayMs * 1000 } }
    /// Idioma/subtítulos preferidos: se aplican una vez por vídeo, al empezar.
    private var prefsApplied = false

    private var url: URL?
    private var live = false
    private var retries = 0
    private var muted = false
    /// true tras halt(): los reintentos pendientes ya no deben arrancar nada.
    private var halted = false
    /// Salto en curso: a dónde se ha pedido ir (VLC tarda un momento en confirmar la nueva posición).
    private var seekTarget: Int?
    private var seekStarted = Date.distantPast

    override init() {
        super.init()
        player.delegate = self
    }

    func start(url: URL, startMs: Int, live: Bool, muted: Bool = false) {
        self.url = url
        self.live = live
        self.muted = muted
        halted = false
        seekTarget = nil
        failed = false
        ended = false
        prefsApplied = false
        buffering = true
        let media = VLCMedia(url: url)
        media.addOption(":network-caching=\(live ? (muted ? 1500 : 2500) : 4000)")
        if muted { media.addOption(":no-audio") }
        if startMs > 0 { media.addOption(":start-time=\(Double(startMs) / 1000.0)") }
        player.media = media
        player.play()
    }

    func restart() {
        retries = 0
        guard let url else { return }
        start(url: url, startMs: live ? 0 : timeMs, live: live)
    }

    func toggle() {
        if player.isPlaying { player.pause() } else { player.play() }
    }

    func seek(toFraction f: Double) {
        let frac = max(0, min(1, f))
        if lengthMs > 0 {
            seek(toMs: Int(Double(lengthMs) * frac))
            return
        }
        player.position = Float(frac)
    }

    func jump(_ seconds: Int32) {
        seek(toMs: (seekTarget ?? timeMs) + Int(seconds) * 1000)
    }

    /// Salto a un tiempo absoluto. Varios saltos seguidos se encadenan desde el último destino
    /// pedido, y si hay un corte mientras tanto se retoma desde ahí, no desde el sitio viejo.
    private func seek(toMs requested: Int) {
        let target = max(0, lengthMs > 0 ? min(requested, lengthMs - 2000) : requested)
        guard target != (seekTarget ?? timeMs) else { return }
        seekTarget = target
        seekStarted = Date()
        timeMs = target
        buffering = true
        player.time = VLCTime(int: Int32(clamping: target))
    }

    func stop() {
        player.delegate = nil
        player.stop()
    }

    /// Para la reproducción pero deja el controlador listo para otro start() (vista previa).
    func halt() {
        halted = true
        retries = 0
        player.stop()
        playing = false
        buffering = false
        failed = false
    }

    // MARK: Pistas de audio y subtítulos

    var audioTracks: [Track] { tracks(player.audioTrackIndexes, player.audioTrackNames) }
    var subtitleTracks: [Track] { tracks(player.videoSubTitlesIndexes, player.videoSubTitlesNames) }
    var currentAudio: Int32 { player.currentAudioTrackIndex }
    var currentSubtitle: Int32 { player.currentVideoSubTitleIndex }

    func setAudio(_ id: Int32) {
        player.currentAudioTrackIndex = id
        objectWillChange.send()
    }

    func setSubtitle(_ id: Int32) {
        player.currentVideoSubTitleIndex = id
        objectWillChange.send()
    }

    /// Ajustes > Reproducción: audio y subtítulos preferidos.
    private func applyPreferredTracks() {
        let audioPref = PlaybackPrefs.audio
        if !audioPref.isEmpty, let t = audioTracks.first(where: { $0.id >= 0 && PlaybackPrefs.matches($0.name, audioPref) }) {
            setAudio(t.id)
        }
        switch PlaybackPrefs.subs {
        case "": break
        case "off": setSubtitle(-1)
        case let pref:
            if let t = subtitleTracks.first(where: { $0.id >= 0 && PlaybackPrefs.matches($0.name, pref) }) {
                setSubtitle(t.id)
            } else if pref == "forzados" {
                setSubtitle(-1)
            }
        }
    }

    /// Guarda las cadenas C que pide VLC (no las libera mientras las usa).
    private var aspectCString: UnsafeMutablePointer<CChar>?
    private var cropCString: UnsafeMutablePointer<CChar>?

    private func applyAspect() {
        let oldAspect = aspectCString, oldCrop = cropCString
        aspectCString = nil
        cropCString = nil
        switch aspect {
        case .fit:
            break
        case .fill:
            // recorta el vídeo a la forma de la pantalla (sin bandas negras)
            let b = UIScreen.main.bounds
            let w = Int(max(b.width, b.height)), h = Int(min(b.width, b.height))
            cropCString = strdup("\(w):\(h)")
        case .wide:
            aspectCString = strdup("16:9")
        case .classic:
            aspectCString = strdup("4:3")
        }
        player.videoAspectRatio = aspectCString
        player.videoCropGeometry = cropCString
        free(oldAspect)
        free(oldCrop)
    }

    private func tracks(_ indexes: [Any]?, _ names: [Any]?) -> [Track] {
        let ids = (indexes ?? []).compactMap { ($0 as? NSNumber)?.int32Value }
        let titles = (names ?? []).map { "\($0)" }
        return zip(ids, titles).map { Track(id: $0, name: $1) }
    }

    // MARK: VLCMediaPlayerDelegate

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch self.player.state {
            case .opening:
                self.buffering = true
            case .buffering:
                if !self.player.isPlaying { self.buffering = true }
            case .playing:
                self.buffering = false
                self.playing = true
                self.retries = 0
                if !self.prefsApplied, !self.muted {
                    self.prefsApplied = true
                    // las pistas aparecen un instante después de empezar
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.applyPreferredTracks() }
                    self.applyAspect()
                    if self.subtitleDelayMs != 0 { self.player.currentVideoSubTitleDelay = self.subtitleDelayMs * 1000 }
                    if self.audioDelayMs != 0 { self.player.currentAudioPlaybackDelay = self.audioDelayMs * 1000 }
                }
            case .paused:
                self.playing = false
            case .error:
                self.handleError()
            case .ended:
                if self.live { self.handleError() } else { self.ended = true }
            case .stopped:
                self.playing = false
            default:
                break
            }
        }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let t = Int(self.player.time.intValue)
            if let target = self.seekTarget {
                // Hasta que VLC llega al destino, sus tiempos son del sitio viejo: no los enseñamos.
                if abs(t - target) > 15_000 && Date().timeIntervalSince(self.seekStarted) < 20 { return }
                self.seekTarget = nil
            }
            self.timeMs = t
            if let len = self.player.media?.length.intValue, len > 0 { self.lengthMs = Int(len) }
            if self.buffering { self.buffering = false }
            if !self.playing && self.player.isPlaying { self.playing = true }
        }
    }

    /// Como mucho 3 reintentos y con pausa creciente: el proveedor banea las ráfagas.
    private func handleError() {
        if halted { return }
        guard retries < 3, let url else {
            failed = true
            buffering = false
            playing = false
            return
        }
        retries += 1
        buffering = true
        let resumeAt = live ? 0 : (seekTarget ?? timeMs)
        let isLive = live
        let isMuted = muted
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(3 * retries)) { [weak self] in
            guard let self, !self.halted, self.url == url else { return }
            self.start(url: url, startMs: resumeAt, live: isLive, muted: isMuted)
        }
    }
}

struct VLCVideoView: UIViewRepresentable {
    let controller: VLCController

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .black
        // Las vistas de VLC no deben quedarse con los toques: si no, los controles
        // de SwiftUI nunca reciben el "tap" y no se puede salir del reproductor.
        v.isUserInteractionEnabled = false
        controller.player.drawable = v
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

struct PlayerView: View {
    /// Lo que se está reproduciendo (cambia al pasar al siguiente capítulo).
    @State private var item: PlayItem
    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vlc = VLCController()
    @State private var showControls = true
    @State private var hideWork: DispatchWorkItem?
    @State private var scrub: Double?
    @State private var epg: [EPGEntry] = []
    /// Directo: posición del canal actual dentro de item.channels (para anterior/siguiente).
    @State private var channelIndex: Int?
    @State private var zapWork: DispatchWorkItem?
    /// Siguiente capítulo: cuenta atrás al acabar.
    @State private var upNext: PlayItem?
    @State private var countdown = 10
    /// Temporizador de apagado.
    @State private var sleepEnd: Date?
    @State private var sleepAtEnd = false
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    private let second = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(item: PlayItem) {
        _item = State(initialValue: item)
    }

    private var currentChannel: LiveStream? {
        guard let i = channelIndex, item.channels.indices.contains(i) else { return nil }
        return item.channels[i]
    }
    private var title: String { currentChannel?.name.channelLabel.name ?? item.title }
    private var canZap: Bool { item.isLive && item.channels.count > 1 && item.channelURL != nil }
    private var remainingMs: Int { max(0, vlc.lengthMs - vlc.timeMs) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VLCVideoView(controller: vlc).ignoresSafeArea()
            // Capa que recibe los toques encima del vídeo (muestra/oculta los controles).
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
                    if showControls { scheduleHide() }
                }
                // Directo: deslizar a izquierda/derecha cambia de canal.
                .gesture(DragGesture(minimumDistance: 40).onEnded { v in
                    let dx = v.translation.width, dy = v.translation.height
                    guard canZap, abs(dx) > 80, abs(dx) > abs(dy) * 1.5 else { return }
                    zap(dx < 0 ? 1 : -1)
                })
            if vlc.buffering && !vlc.failed && upNext == nil {
                ProgressView().controlSize(.large).tint(.white).allowsHitTesting(false)
            }
            if let next = upNext {
                upNextCard(next)
            } else if vlc.failed {
                failure
            } else if showControls {
                controls.transition(.opacity)
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            setOrientation(.landscape)
            if item.isLive, !item.channels.isEmpty { channelIndex = item.channelIndex }
            // la cuenta solo admite una conexión: si se está descargando algo, se pausa mientras tanto
            if !item.url.isFileURL { Downloads.shared.pauseForPlayback() }
            vlc.start(url: item.url, startMs: item.startMs, live: item.isLive)
            rememberChannel()
            setUpRemoteCommands()
            scheduleHide()
        }
        .onDisappear {
            report()
            vlc.stop()
            tearDownRemoteCommands()
            Downloads.shared.resumeAfterPlayback()
            UIApplication.shared.isIdleTimerDisabled = false
            setOrientation(.portrait)
        }
        .onReceive(tick) { _ in
            report()
            updateNowPlaying()
        }
        .onReceive(second) { _ in secondTick() }
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
                        if let end = sleepEnd {
                            Label("Se apaga a las \(end.formatted(date: .omitted, time: .shortened))", systemImage: "moon.zzz")
                                .font(.caption).opacity(0.8)
                        } else if sleepAtEnd {
                            Label("Se apaga al terminar", systemImage: "moon.zzz").font(.caption).opacity(0.8)
                        }
                    }
                    Spacer()
                    optionsMenu
                    if !vlc.audioTracks.isEmpty || !vlc.subtitleTracks.isEmpty { tracksMenu }
                }
                .padding()

                Spacer()

                HStack(spacing: 52) {
                    if !item.isLive {
                        Button { vlc.jump(-10); scheduleHide() } label: { Image(systemName: "gobackward.10").font(.system(size: 34)) }
                            .accessibilityLabel("Atrasar 10 segundos")
                    } else if canZap {
                        Button { zap(-1) } label: { Image(systemName: "backward.end.fill").font(.system(size: 32)) }
                            .accessibilityLabel("Canal anterior")
                    }
                    Button { vlc.toggle(); scheduleHide() } label: {
                        Image(systemName: vlc.playing ? "pause.fill" : "play.fill").font(.system(size: 46))
                    }
                    .accessibilityLabel(vlc.playing ? "Pausa" : "Reproducir")
                    if !item.isLive {
                        Button { vlc.jump(30); scheduleHide() } label: { Image(systemName: "goforward.30").font(.system(size: 34)) }
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
                } else if vlc.lengthMs > 0 {
                    VStack(alignment: .trailing, spacing: 8) {
                        // En los créditos: pasar ya al siguiente capítulo.
                        if item.next != nil, remainingMs < 90_000, remainingMs > 0 {
                            Button { playNextNow() } label: {
                                Label("Siguiente capítulo", systemImage: "forward.end.fill")
                                    .font(.subheadline.bold())
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(.ultraThinMaterial, in: Capsule())
                            }
                        }
                        seekBar
                    }
                    .padding(.horizontal).padding(.bottom, 14)
                }
            }
            .foregroundStyle(.white)
        }
    }

    private var seekBar: some View {
        VStack(spacing: 4) {
            Slider(value: Binding(get: { scrub ?? fraction }, set: { scrub = $0 }), in: 0...1, onEditingChanged: { editing in
                hideWork?.cancel()
                if !editing, let f = scrub {
                    vlc.seek(toFraction: f)
                    scrub = nil
                    scheduleHide()
                }
            })
            .accessibilityLabel("Posición")
            HStack {
                Text(timeText(scrub.map { Int($0 * Double(vlc.lengthMs)) } ?? vlc.timeMs))
                Spacer()
                Text(timeText(vlc.lengthMs))
            }
            .font(.caption.monospacedDigit())
        }
    }

    private var fraction: Double {
        vlc.lengthMs > 0 ? Double(vlc.timeMs) / Double(vlc.lengthMs) : 0
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

    /// Formato de imagen y temporizador de apagado.
    private var optionsMenu: some View {
        Menu {
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

    private var failure: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle)
            Text("No se ha podido reproducir").font(.headline)
            Text("Puede que no esté disponible ahora mismo. Prueba en unos minutos.")
                .font(.subheadline).multilineTextAlignment(.center).opacity(0.8)
            HStack(spacing: 16) {
                Button("Reintentar") { vlc.restart() }.buttonStyle(.borderedProminent)
                Button("Cerrar") { dismiss() }.buttonStyle(.bordered)
            }
        }
        .foregroundStyle(.white)
        .padding(30)
    }

    // MARK: Lógica

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { withAnimation(.easeInOut(duration: 0.3)) { showControls = false } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    private func report(final: Bool = false) {
        guard !item.isLive else { return }
        let len = vlc.lengthMs
        session.report(item, timeMs: final ? len : vlc.timeMs, lengthMs: len)
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
        guard canZap, let i = channelIndex, let urlFor = item.channelURL else { return }
        let n = item.channels.count
        let next = ((i + step) % n + n) % n
        channelIndex = next
        epg = []
        showControls = true
        scheduleHide()
        zapWork?.cancel()
        let channel = item.channels[next]
        let work = DispatchWorkItem {
            vlc.start(url: urlFor(channel), startMs: 0, live: true)
            rememberChannel()
            updateNowPlaying()
            Task { await loadEPG() }
        }
        zapWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func rememberChannel() {
        guard item.isLive else { return }
        if let c = currentChannel { session.lastChannelID = c.id } else if let id = item.liveStreamId { session.lastChannelID = id }
    }

    @MainActor
    private func loadEPG() async {
        guard item.isLive else { return }
        // Guía del panel (una sola descarga para todos los canales) si la hay.
        if let c = currentChannel, session.guideEnabled {
            await session.refreshGuide()
            let g = session.nowNext(c)
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

    // MARK: Pantalla de bloqueo / Centro de control

    private func setUpRemoteCommands() {
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.addTarget { _ in vlc.player.play(); return .success }
        cc.pauseCommand.addTarget { _ in vlc.player.pause(); return .success }
        cc.togglePlayPauseCommand.addTarget { _ in vlc.toggle(); return .success }
        if item.isLive {
            cc.nextTrackCommand.addTarget { _ in zap(1); return .success }
            cc.previousTrackCommand.addTarget { _ in zap(-1); return .success }
        } else {
            cc.skipForwardCommand.preferredIntervals = [30]
            cc.skipBackwardCommand.preferredIntervals = [10]
            cc.skipForwardCommand.addTarget { _ in vlc.jump(30); return .success }
            cc.skipBackwardCommand.addTarget { _ in vlc.jump(-10); return .success }
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
                                   MPNowPlayingInfoPropertyPlaybackRate: vlc.playing ? 1.0 : 0.0,
                                   MPNowPlayingInfoPropertyIsLiveStream: item.isLive]
        if let s = item.subtitle { info[MPMediaItemPropertyArtist] = s }
        if !item.isLive, vlc.lengthMs > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = Double(vlc.lengthMs) / 1000
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(vlc.timeMs) / 1000
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
