import SwiftUI
import VLCKit

struct Track: Identifiable, Hashable {
    let id: Int32
    let name: String
}

/// Envoltorio del motor VLC 4 (reproduce TS, MKV, AVI…) con imagen en imagen (PiP).
final class VLCController: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    let player = VLCMediaPlayer()

    @Published var playing = false
    @Published var buffering = true
    @Published var timeMs = 0
    @Published var lengthMs = 0
    @Published var failed = false
    @Published var ended = false
    /// PiP listo para usarse (VLC lo avisa cuando la vista ya está montada).
    @Published var pipAvailable = false
    @Published var pipActive = false

    weak var pipController: VLCPictureInPictureWindowControlling?

    private var url: URL?
    private var live = false
    private var retries = 0
    private var muted = false
    /// true tras halt()/stop(): los reintentos pendientes y el "stopped" que llega después se ignoran.
    private var halted = false
    /// Salto en curso: a dónde se ha pedido ir y cuándo (VLC tarda en confirmar la nueva posición).
    private var seekTarget: Int?
    private var seekStarted = Date.distantPast
    /// Pistas a recuperar tras reabrir el vídeo en otro punto (nombres de audio y subtítulos).
    private var restoreTracks: (audio: String?, text: String?)?
    /// Al cambiar de vídeo VLC avisa "parado" del anterior: no es un corte.
    private var ignoreStopUntil = Date.distantPast

    override init() {
        super.init()
        player.delegate = self
    }

    func start(url: URL, startMs: Int, live: Bool, muted: Bool = false) {
        self.url = url
        self.live = live
        self.muted = muted
        halted = false
        failed = false
        ended = false
        buffering = true
        seekTarget = nil
        restoreTracks = nil
        ignoreStopUntil = Date().addingTimeInterval(3)
        guard let media = VLCMedia(url: url) else { failed = true; return }
        media.addOption(":network-caching=\(live ? (muted ? 1500 : 2500) : 4000)")
        if muted { media.addOption(":no-audio") }
        // Saltos al fotograma clave más cercano (rápido) en vez de decodificar hasta el segundo exacto.
        media.addOption(":input-fast-seek")
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
        guard lengthMs > 0 else { player.position = frac; return }
        seek(toMs: Int(Double(lengthMs) * frac))
    }

    func jump(_ seconds: Int32) {
        seek(toMs: (seekTarget ?? timeMs) + Int(seconds) * 1000)
    }

    /// Salto relativo y rápido (VLC 4: jump = seek "fast"; position/time = seek "preciso", muy lento
    /// en pelis de varios GB). Varios saltos seguidos se encadenan desde el último destino pedido.
    private func seek(toMs requested: Int) {
        let target = max(0, lengthMs > 0 ? min(requested, lengthMs - 2000) : requested)
        let from = seekTarget ?? timeMs
        let offset = target - from
        guard offset != 0 else { return }
        if abs(offset) > 60_000, !live, restoreTracks == nil {
            // Salto grande. Los MKV del proveedor solo tienen índice (Cues) del vídeo: con el audio
            // activo, VLC busca un punto común para todas las pistas, el del audio es el principio
            // del archivo y se lo lee entero por HTTP hasta llegar. Sin audio ni subtítulos salta
            // directo al índice del vídeo; al llegar se vuelven a poner los mismos.
            let audio = player.audioTracks.first(where: { $0.isSelected })?.trackName
            let text = player.textTracks.first(where: { $0.isSelected })?.trackName
            restoreTracks = (audio ?? "", text)
            player.deselectAllAudioTracks()
            player.deselectAllTextTracks()
            // por si VLC no llega a avisar del nuevo tiempo
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.applyRestoredTracks() }
        }
        _ = player.jump(withOffset: Int32(clamping: offset), completion: nil)
        seekTarget = target
        seekStarted = Date()
        timeMs = target
        buffering = true
    }

    /// Tras reabrir: vuelve a poner el idioma y los subtítulos que había.
    private func applyRestoredTracks() {
        guard let r = restoreTracks else { return }
        restoreTracks = nil
        let audios = player.audioTracks
        if let t = audios.first(where: { $0.trackName == r.audio }) ?? audios.first {
            t.isSelectedExclusively = true
        }
        if let name = r.text {
            if let t = player.textTracks.first(where: { $0.trackName == name }) { t.isSelectedExclusively = true }
        } else {
            player.deselectAllTextTracks()
        }
        objectWillChange.send()
    }

    func stop() {
        halted = true
        if pipActive { pipController?.stopPictureInPicture() }
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

    // MARK: Imagen en imagen

    func togglePiP() {
        guard let c = pipController else { return }
        if pipActive { c.stopPictureInPicture() } else { c.startPictureInPicture() }
    }

    func startPiP() {
        guard !pipActive, player.isPlaying else { return }
        pipController?.startPictureInPicture()
    }

    // MARK: Pistas de audio y subtítulos

    var audioTracks: [Track] {
        player.audioTracks.enumerated().map { Track(id: Int32($0.offset), name: $0.element.trackName) }
    }

    /// Con "Desactivados" (-1) al principio, como en VLC 3.
    var subtitleTracks: [Track] {
        let list = player.textTracks.enumerated().map { Track(id: Int32($0.offset), name: $0.element.trackName) }
        return list.isEmpty ? [] : [Track(id: -1, name: "Desactivados")] + list
    }

    var currentAudio: Int32 {
        Int32(player.audioTracks.firstIndex(where: { $0.isSelected }) ?? -1)
    }

    var currentSubtitle: Int32 {
        Int32(player.textTracks.firstIndex(where: { $0.isSelected }) ?? -1)
    }

    func setAudio(_ id: Int32) {
        let list = player.audioTracks
        if list.indices.contains(Int(id)) { list[Int(id)].isSelectedExclusively = true }
        objectWillChange.send()
    }

    func setSubtitle(_ id: Int32) {
        let list = player.textTracks
        if id < 0 {
            player.deselectAllTextTracks()
        } else if list.indices.contains(Int(id)) {
            list[Int(id)].isSelectedExclusively = true
        }
        objectWillChange.send()
    }

    // MARK: VLCMediaPlayerDelegate

    func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch newState {
            case .opening:
                self.buffering = true
            case .playing:
                self.buffering = false
                self.playing = true
                self.retries = 0

                self.pipController?.invalidatePlaybackState()
            case .paused:
                self.playing = false
                self.pipController?.invalidatePlaybackState()
            case .error:
                self.handleError()
            case .stopped:
                self.playing = false
                guard !self.halted, Date() >= self.ignoreStopUntil else { return }
                // VLC 4 no tiene estado "ended": si para solo, o ha llegado al final o se ha cortado.
                if !self.live, self.lengthMs > 0, self.timeMs >= self.lengthMs - 5000 {
                    self.ended = true
                } else {
                    self.handleError()
                }
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
                // ya en el sitio nuevo: vuelven el audio y los subtítulos
                if self.restoreTracks != nil { self.applyRestoredTracks() }
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

/// "Drawable" de VLC 4: VLC monta su vista de vídeo dentro de `view` y, como también es
/// VLCPictureInPictureDrawable, prepara el modo imagen en imagen (mismo esquema que la app de VLC).
final class VLCDrawableHost: NSObject, VLCDrawable, VLCPictureInPictureDrawable, VLCPictureInPictureMediaControlling {
    let view: UIView
    weak var controller: VLCController?

    init(view: UIView, controller: VLCController) {
        self.view = view
        self.controller = controller
    }

    // VLCDrawable
    func addSubview(_ subview: UIView!) {
        view.addSubview(subview)
        subview.frame = view.bounds
        subview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        subview.isUserInteractionEnabled = false
    }

    func bounds() -> CGRect { view.bounds }

    // VLCPictureInPictureDrawable
    func mediaController() -> VLCPictureInPictureMediaControlling! { self }

    func pictureInPictureReady() -> ((VLCPictureInPictureWindowControlling?) -> Void)! {
        { [weak self] pip in
            // (según la cabecera el parámetro puede venir como opcional o no: así vale para los dos)
            let ctl: VLCPictureInPictureWindowControlling? = pip
            guard let c = self?.controller, let pip = ctl else { return }
            DispatchQueue.main.async {
                c.pipController = pip
                c.pipAvailable = true
                pip.stateChangeEventHandler = { [weak c] started in
                    DispatchQueue.main.async {
                        guard let c else { return }
                        c.pipActive = started
                        // Se cierra la ventanita estando fuera de la app: se pausa (como en el resto de apps).
                        if !started, UIApplication.shared.applicationState != .active { c.player.pause() }
                    }
                }
            }
        }
    }

    // VLCPictureInPictureMediaControlling
    func play() { controller?.player.play() }
    func pause() { controller?.player.pause() }

    func seek(by offset: Int64, completion: (() -> Void)!) {
        controller?.player.jump(withOffset: Int32(offset), completion: completion)
    }

    func mediaLength() -> Int64 { controller?.player.media?.length.value?.int64Value ?? 0 }
    func mediaTime() -> Int64 { controller?.player.time.value?.int64Value ?? 0 }
    func isMediaSeekable() -> Bool { controller?.player.isSeekable ?? false }
    func isMediaPlaying() -> Bool { controller?.player.isPlaying ?? false }
}

struct VLCVideoView: UIViewRepresentable {
    let controller: VLCController

    final class Coordinator { var host: VLCDrawableHost? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .black
        // Las vistas de VLC no deben quedarse con los toques: si no, los controles
        // de SwiftUI nunca reciben el "tap" y no se puede salir del reproductor.
        v.isUserInteractionEnabled = false
        let host = VLCDrawableHost(view: v, controller: controller)
        context.coordinator.host = host
        controller.player.drawable = host
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

struct PlayerView: View {
    let item: PlayItem
    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vlc = VLCController()
    @State private var showControls = true
    @State private var hideWork: DispatchWorkItem?
    @State private var scrub: Double?
    @State private var epg: [EPGEntry] = []
    /// Directo: posición del canal actual dentro de item.channels (para anterior/siguiente).
    @State private var channelIndex: Int?
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var currentChannel: LiveStream? {
        guard let i = channelIndex, item.channels.indices.contains(i) else { return nil }
        return item.channels[i]
    }
    private var title: String { currentChannel?.name.channelLabel.name ?? item.title }
    private var canZap: Bool { item.isLive && item.channels.count > 1 && item.channelURL != nil }

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
            if vlc.buffering && !vlc.failed {
                ProgressView().controlSize(.large).tint(.white).allowsHitTesting(false)
            }
            if vlc.failed {
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
            vlc.start(url: item.url, startMs: item.startMs, live: item.isLive)
            scheduleHide()
        }
        .onDisappear {
            report()
            vlc.stop()
            UIApplication.shared.isIdleTimerDisabled = false
            setOrientation(.portrait)
        }
        .onReceive(tick) { _ in report() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            vlc.startPiP()
        }
        .onChange(of: vlc.ended) { done in
            if done {
                report(final: true)
                dismiss()
            }
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
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.headline).lineLimit(1)
                        if let s = item.subtitle { Text(s).font(.subheadline).opacity(0.8).lineLimit(1) }
                        if let now = epg.first { Text("Ahora: \(now.title)").font(.subheadline).lineLimit(1) }
                        if epg.count > 1 { Text("Después: \(epg[1].title)").font(.caption).opacity(0.75).lineLimit(1) }
                    }
                    Spacer()
                    if vlc.pipAvailable {
                        Button { vlc.togglePiP(); scheduleHide() } label: {
                            Image(systemName: vlc.pipActive ? "pip.exit" : "pip.enter")
                                .font(.title3)
                                .padding(12)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                    }
                    if !vlc.audioTracks.isEmpty || !vlc.subtitleTracks.isEmpty { tracksMenu }
                }
                .padding()

                Spacer()

                HStack(spacing: 52) {
                    if !item.isLive {
                        Button { vlc.jump(-10); scheduleHide() } label: { Image(systemName: "gobackward.10").font(.system(size: 34)) }
                    } else if canZap {
                        Button { zap(-1) } label: { Image(systemName: "backward.end.fill").font(.system(size: 32)) }
                    }
                    Button { vlc.toggle(); scheduleHide() } label: {
                        Image(systemName: vlc.playing ? "pause.fill" : "play.fill").font(.system(size: 46))
                    }
                    if !item.isLive {
                        Button { vlc.jump(30); scheduleHide() } label: { Image(systemName: "goforward.30").font(.system(size: 34)) }
                    } else if canZap {
                        Button { zap(1) } label: { Image(systemName: "forward.end.fill").font(.system(size: 32)) }
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
                    seekBar.padding(.horizontal).padding(.bottom, 14)
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
        } label: {
            Image(systemName: "captions.bubble")
                .font(.title3)
                .padding(12)
                .background(.ultraThinMaterial, in: Circle())
        }
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

    /// Canal anterior (-1) o siguiente (+1) de la lista desde la que se abrió.
    private func zap(_ step: Int) {
        guard canZap, let i = channelIndex, let urlFor = item.channelURL else { return }
        let n = item.channels.count
        let next = ((i + step) % n + n) % n
        channelIndex = next
        epg = []
        vlc.start(url: urlFor(item.channels[next]), startMs: 0, live: true)
        scheduleHide()
        Task { await loadEPG() }
    }

    @MainActor
    private func loadEPG() async {
        guard item.isLive, let api = session.api else { return }
        // Solo canales Xtream tienen guía (los M3U no traen stream_id del servidor).
        let id = currentChannel.map { $0.directURL == nil ? $0.id : nil } ?? item.liveStreamId
        guard let id else { return }
        epg = (try? await api.shortEPG(id)) ?? []
    }
}
