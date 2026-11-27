import Foundation
import UIKit
import MetricKit

// Telemetría anónima (contrato: carraca-android/tools/telemetria/SCHEMA.md; servidor: telemetria.php).
// Nunca se envía: usuario, contraseña, URLs, nombres de canal/película, IP ni identificadores del aparato
// (solo un UUID propio, que se regenera al apagar). Los errores van como códigos, nunca como texto.

/// Valor de un campo del esquema: entero, texto corto (clases/símbolos/códigos) o lista de símbolos.
enum TVal: Sendable {
    case i(Int)
    case s(String)
    case l([String])

    fileprivate var json: Any {
        switch self {
        case .i(let v): return v
        case .s(let v): return v
        case .l(let v): return v
        }
    }
}

/// Cola de eventos con límites, envío por lotes y MetricKit. Todo el estado mutable se toca solo en `q`.
final class Telemetry: @unchecked Sendable {
    static let shared = Telemetry()

    /// Interruptor de Ajustes (por defecto encendido).
    static let enabledKey = "carraca.telemetry.enabled"
    private static let iidKey = "carraca.telemetry.iid"
    private static let endpoint = URL(string: AppConfig.panel + "/telemetria.php")!

    private static let maxBufferEvents = 200
    private static let maxBufferBytes = 64 * 1024
    private static let maxSendEvents = 100
    /// Margen bajo el límite de 32 KB del servidor (el sobre "env" ocupa unos cientos de bytes).
    private static let maxPayloadBytes = 30 * 1024
    private static let minSendInterval: TimeInterval = 300

    private let q = DispatchQueue(label: "carraca.telemetry", qos: .utility)
    private let lock = NSLock()
    private let metricSubscriber = MetricKitSubscriber()

    // Solo en `q`:
    private struct Item {
        let seq: Int
        let line: Data      // un objeto JSON por evento, sin salto de línea
    }
    private var buffer: [Item] = []
    private var nextSeq = 0
    private var inFlight = false
    private var lastSendAt = Date.distantPast
    private var zapCount = 0
    private var startLogged = false

    // Protegido por `lock` (lo leen y escriben hilos distintos):
    private var playbackOn = false

    private init() {}

    // MARK: Arranque y ciclo de vida

    /// Llamar una vez al arrancar la app: MetricKit, aviso de poca memoria y carga del buffer guardado.
    func start() {
        _ = Self.installID
        _ = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                                   object: nil, queue: nil) { _ in
            Telemetry.shared.log("lowmem", ["lvl": .i(1),
                                            "where": .s(Telemetry.shared.isPlaybackActive ? "player" : "ui")])
        }
        MXMetricManager.shared.add(metricSubscriber)
        q.async { self.loadBuffer() }
    }

    /// Primera pantalla útil: un evento `start` por proceso, con el tiempo desde que se lanzó.
    func logStart() {
        let cold = Self.coldStartMs()
        q.async { [weak self] in
            guard let self, !self.startLogged else { return }
            self.startLogged = true
            var f: [String: TVal] = [:]
            if let cold { f["cold_ms"] = .i(cold) }
            self.enqueue("start", f)
        }
    }

    /// Intento de envío al pasar a segundo plano.
    func flush() {
        q.async { self.trySend() }
    }

    /// Intento de envío al arrancar, con un retardo para no pesar en el arranque.
    func flushAtLaunch() {
        q.asyncAfter(deadline: .now() + 15) { self.trySend() }
    }

    /// Reproducción activa (VLCController): no se envía nada mientras dure.
    func setPlaybackActive(_ on: Bool) {
        lock.lock()
        playbackOn = on
        lock.unlock()
    }

    var isPlaybackActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return playbackOn
    }

    /// Apagado desde Ajustes: se borra lo pendiente y se regenera el identificador. No se envía nada más.
    func disable() {
        UserDefaults.standard.set(UUID().uuidString.lowercased(), forKey: Self.iidKey)
        q.async {
            self.buffer.removeAll()
            self.zapCount = 0
            self.saveBuffer()
        }
    }

    // MARK: Anotar eventos

    /// Anota un evento (campos del esquema). No hace nada si la telemetría está apagada.
    func log(_ event: String, _ fields: [String: TVal]) {
        guard Self.isEnabled else { return }
        q.async { self.enqueue(event, fields) }
    }

    /// Una sesión corta de zapping (< 5 s): se suma al contador que sale en el próximo envío.
    func countZap() {
        guard Self.isEnabled else { return }
        q.async { self.zapCount += 1 }
    }

    // MARK: Trabajo en la cola `q`

    private func enqueue(_ event: String, _ fields: [String: TVal]) {
        guard Self.isEnabled else { return }
        var obj: [String: Any] = fields.mapValues { $0.json }
        obj["e"] = event
        obj["t"] = Int(Date().timeIntervalSince1970)
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              data.count <= 4096 else { return }
        // defensa en profundidad: nada que parezca URL, credencial o dirección
        let text = String(decoding: data, as: UTF8.self)
        if text.contains("://") || text.contains("@") || text.contains("?") || text.contains("=") || text.contains("&") {
            return
        }
        nextSeq += 1
        buffer.append(Item(seq: nextSeq, line: data))
        trim()
        saveBuffer()
    }

    /// Mantiene el buffer dentro de sus límites tirando lo más viejo.
    private func trim() {
        var bytes = buffer.reduce(0) { $0 + $1.line.count }
        while !buffer.isEmpty && (buffer.count > Self.maxBufferEvents || bytes > Self.maxBufferBytes) {
            bytes -= buffer[0].line.count
            buffer.removeFirst()
        }
    }

    private func trySend() {
        guard Self.isEnabled, !inFlight, !isPlaybackActive else { return }
        guard Date().timeIntervalSince(lastSendAt) >= Self.minSendInterval else { return }
        if zapCount > 0 {
            enqueue("zaps", ["n": .i(min(zapCount, 100_000))])
            zapCount = 0
        }
        guard !buffer.isEmpty, let env = envelopeJSON() else { return }

        var batch: [Item] = []
        var size = 0
        for item in buffer {
            if batch.count >= Self.maxSendEvents || size + item.line.count + 1 > Self.maxPayloadBytes { break }
            batch.append(item)
            size += item.line.count + 1
        }
        guard !batch.isEmpty else { return }

        var body = Data("{\"env\":".utf8)
        body.append(env)
        body.append(Data(",\"ev\":[".utf8))
        for (i, item) in batch.enumerated() {
            if i > 0 { body.append(UInt8(ascii: ",")) }
            body.append(item.line)
        }
        body.append(Data("]}".utf8))

        inFlight = true
        lastSendAt = Date()
        let sent = Set(batch.map { $0.seq })
        var req = URLRequest(url: Self.endpoint, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        URLSession.shared.dataTask(with: req) { [weak self] _, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            self?.q.async { self?.finishSend(sent, accepted: code == 204 || code == 200) }
        }.resume()
    }

    /// Solo se quita del buffer lo aceptado. Si falla, se queda para el siguiente intento (sin bucles).
    private func finishSend(_ sent: Set<Int>, accepted: Bool) {
        inFlight = false
        guard accepted else { return }
        buffer.removeAll { sent.contains($0.seq) }
        saveBuffer()
    }

    private func envelopeJSON() -> Data? {
        let v = AppConfig.version.isEmpty ? "0" : AppConfig.version
        let model = Self.hardwareModel()
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let obj: [String: Any] = [
            "iid": Self.installID,
            "app": "ios",
            "v": v,
            "build": Self.buildKind,
            "model": model.isEmpty ? "unknown" : model,
            "os": "iOS \(os.majorVersion).\(os.minorVersion)",
            "ram_mb": Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)
        ]
        return try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }

    // MARK: Fichero del buffer (Application Support/Telemetry/buffer.jsonl)

    private static let bufferURL: URL? = {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true) else { return nil }
        let dir = base.appendingPathComponent("Telemetry", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("buffer.jsonl")
    }()

    private func saveBuffer() {
        guard let url = Self.bufferURL else { return }
        if buffer.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        var out = Data()
        for item in buffer {
            out.append(item.line)
            out.append(UInt8(ascii: "\n"))
        }
        try? out.write(to: url, options: .atomic)
    }

    private func loadBuffer() {
        guard Self.isEnabled, let url = Self.bufferURL, let data = try? Data(contentsOf: url) else { return }
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            nextSeq += 1
            buffer.append(Item(seq: nextSeq, line: Data(line)))
        }
        trim()
    }

    // MARK: Datos del aparato y de la app

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Identificador anónimo de la instalación (UUID v4 en minúsculas, como exige el servidor).
    static var installID: String {
        let d = UserDefaults.standard
        if let s = d.string(forKey: iidKey), !s.isEmpty { return s }
        let s = UUID().uuidString.lowercased()
        d.set(s, forKey: iidKey)
        return s
    }

    private static var buildKind: String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }

    /// Identificador de hardware tipo "iPhone15,2" (no el nombre que el usuario pone al aparato).
    static func hardwareModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        var model = ""
        for child in mirror.children {
            guard let value = child.value as? Int8, value > 0 else { continue }
            model.append(Character(UnicodeScalar(UInt8(value))))
        }
        return model
    }

    /// Milisegundos desde que se lanzó este proceso (kinfo_proc, sin nombres ni rutas).
    private static func coldStartMs() -> Int? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        // p_starttime es una macro de C para p_un.__p_starttime: en Swift se usa el nombre real
        let tv = info.kp_proc.p_un.__p_starttime
        let started = TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000
        let ms = (Date().timeIntervalSince1970 - started) * 1000
        return (ms > 0 && ms < 600_000) ? Int(ms) : nil
    }
}

/// Recibe de MetricKit los diagnósticos (cierres, bloqueos) y los resúmenes de rendimiento.
/// Solo se leen códigos y frames simbolizables; nunca los mensajes ni los textos de error.
final class MetricKitSubscriber: NSObject, MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXMetricPayload]) {
        for p in payloads {
            Telemetry.shared.log("mx", Self.metricFields(p))
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for p in payloads {
            for c in p.crashDiagnostics ?? [] {
                var f: [String: TVal] = ["cls": .s(Self.crashClass(sig: c.signal?.intValue, exc: c.exceptionType?.intValue))]
                let top = Self.topFrames(c.callStackTree)
                if !top.isEmpty { f["top"] = .l(top) }
                Telemetry.shared.log("crash", f)
            }
            for h in p.hangDiagnostics ?? [] {
                let ms = Int(h.hangDuration.converted(to: .milliseconds).value)
                Telemetry.shared.log("hang", ["ms": .i(min(max(ms, 0), 600_000))])
            }
        }
    }

    // MARK: Crashes

    private static let signalNames: [Int: String] = [
        4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT", 7: "SIGEMT", 8: "SIGFPE",
        9: "SIGKILL", 10: "SIGBUS", 11: "SIGSEGV", 12: "SIGSYS"
    ]
    private static let exceptionNames: [Int: String] = [
        1: "EXC_BAD_ACCESS", 2: "EXC_BAD_INSTRUCTION", 3: "EXC_ARITHMETIC", 4: "EXC_EMULATION",
        5: "EXC_SOFTWARE", 6: "EXC_BREAKPOINT", 10: "EXC_CRASH", 11: "EXC_RESOURCE", 12: "EXC_GUARD"
    ]

    /// "SIGSEGV/EXC_BAD_ACCESS": texto corto, sin mensaje. Sin "?" (el filtro del buffer y el servidor lo rechazan).
    private static func crashClass(sig: Int?, exc: Int?) -> String {
        let s = sig.map { signalNames[$0] ?? "SIG\($0)" } ?? "SIG0"
        let e = exc.map { exceptionNames[$0] ?? "EXC\($0)" } ?? "EXC0"
        return "\(s)/\(e)"
    }

    /// Hasta 8 frames de la rama con más muestras del hilo que cayó, como "Binario:offset_hex".
    /// MetricKit no trae nombres de funciones: el símbolo se resuelve con el dSYM del binario.
    private static func topFrames(_ tree: MXCallStackTree?) -> [String] {
        guard let tree,
              let obj = try? JSONSerialization.jsonObject(with: tree.jsonRepresentation()) as? [String: Any],
              let stacks = obj["callStacks"] as? [[String: Any]] else { return [] }
        let stack = stacks.first(where: { ($0["threadAttributed"] as? Bool) == true }) ?? stacks.first
        var node = (stack?["callStackRootFrames"] as? [[String: Any]]) ?? []
        var out: [String] = []
        while out.count < 8, let frame = node.max(by: { ($0["sampleCount"] as? Int ?? 0) < ($1["sampleCount"] as? Int ?? 0) }) {
            let name = (frame["binaryName"] as? String) ?? "unknown"
            let off = (frame["offsetIntoBinaryTextSegment"] as? Int) ?? 0
            out.append(name + ":" + String(off, radix: 16))
            node = (frame["subFrames"] as? [[String: Any]]) ?? []
        }
        return out
    }

    // MARK: Rendimiento

    private static func metricFields(_ p: MXMetricPayload) -> [String: TVal] {
        var f: [String: TVal] = [:]
        if let h = p.applicationLaunchMetrics?.histogrammedTimeToFirstDraw, let ms = medianMs(h) {
            f["launch_ms"] = .i(min(ms, 600_000))
        }
        if let h = p.applicationResponsivenessMetrics?.histogrammedApplicationHangTime {
            f["hang_ms"] = .i(Int(totalMs(h)))
        }
        if let cpu = p.cpuMetrics?.cumulativeCPUTime {
            f["cpu_s"] = .i(Int(cpu.converted(to: .seconds).value))
        }
        if let mem = p.memoryMetrics?.peakMemoryUsage {
            f["mem_peak_mb"] = .i(Int(mem.converted(to: .megabytes).value))
        }
        // hitch_pct se omite a propósito: no está confirmada la unidad de scrollHitchTimeRatio
        return f
    }

    private static func buckets(_ h: MXHistogram<UnitDuration>) -> [(startMs: Double, endMs: Double, count: Int)] {
        var out: [(startMs: Double, endMs: Double, count: Int)] = []
        let en = h.bucketEnumerator
        while let b = en.nextObject() as? MXHistogramBucket<UnitDuration> {
            out.append((b.bucketStart.converted(to: .milliseconds).value,
                        b.bucketEnd.converted(to: .milliseconds).value,
                        b.bucketCount))
        }
        return out
    }

    /// Mediana aproximada: inicio del cubo donde se alcanza la mitad de las muestras.
    private static func medianMs(_ h: MXHistogram<UnitDuration>) -> Int? {
        let bs = buckets(h)
        let total = bs.reduce(0) { $0 + $1.count }
        guard total > 0 else { return nil }
        var acc = 0
        for b in bs {
            acc += b.count
            if acc * 2 >= total { return Int(b.startMs) }
        }
        return nil
    }

    private static func totalMs(_ h: MXHistogram<UnitDuration>) -> Double {
        buckets(h).reduce(0) { $0 + Double($1.count) * ($1.startMs + $1.endMs) / 2 }
    }
}
