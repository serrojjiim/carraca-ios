import Foundation
import UserNotifications

// MARK: - Avisos de programas ("Avisarme": empieza en N min)

/// Un aviso programado. Se guarda en el dispositivo (la clave del canal es de esta cuenta).
struct ProgramReminder: Codable, Identifiable, Equatable {
    /// Clave del canal igual que los favoritos: la URL directa o "x<id>". Sirve para reabrirlo.
    let channelKey: String
    let channelID: Int
    let channelName: String
    let title: String
    let start: Date

    var id: String { ProgramReminder.key(channelKey, start) }

    static func key(_ channelKey: String, _ start: Date) -> String {
        channelKey + "|" + String(Int(start.timeIntervalSince1970))
    }
}

@MainActor
final class ProgramReminders: ObservableObject {
    static let shared = ProgramReminders()

    /// iOS deja hasta 64 avisos locales pendientes en total (contando los de eventos).
    static let maxPending = 60
    static let notificationPrefix = "prog|"
    /// Minutos antes del inicio (Ajustes > Recordatorios).
    static let leadKey = "carraca.remind.lead"
    static let leadOptions = [5, 10, 15]
    private static let storeKey = "carraca.reminders"

    @Published private(set) var reminders: [ProgramReminder] = []

    private init() {
        load()
        prune()
    }

    static var lead: Int {
        let v = UserDefaults.standard.integer(forKey: leadKey)
        return leadOptions.contains(v) ? v : 5
    }

    private func fireDate(_ r: ProgramReminder) -> Date {
        r.start.addingTimeInterval(-Double(Self.lead * 60))
    }

    func isReminded(channelKey: String, start: Date) -> Bool {
        let id = ProgramReminder.key(channelKey, start)
        return reminders.contains { $0.id == id }
    }

    /// Programa el aviso. Devuelve el mensaje de error, o nil si quedó programado.
    func add(_ r: ProgramReminder) async -> String? {
        if reminders.contains(where: { $0.id == r.id }) { return nil }
        guard fireDate(r).timeIntervalSinceNow > 5 else {
            return "Ya no da tiempo a avisarte de este programa."
        }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            let ok = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            if !ok { return "Activa los avisos de Carraca en Ajustes del iPhone para usar los recordatorios." }
        } else if settings.authorizationStatus == .denied {
            return "Los avisos están desactivados. Actívalos en Ajustes del iPhone > Carraca."
        }
        let active = reminders.filter { fireDate($0).timeIntervalSinceNow > 0 }.count
        if active >= Self.maxPending {
            return "Tienes demasiados avisos programados. Quita alguno en Ajustes para añadir otro."
        }
        let pending = await center.pendingNotificationRequests().count
        if pending >= 64 {
            return "iOS no admite más avisos pendientes. Quita alguno en Ajustes para añadir otro."
        }
        do {
            try await center.add(request(for: r))
        } catch {
            return "No se ha podido programar el aviso."
        }
        reminders.append(r)
        reminders.sort { $0.start < $1.start }
        save()
        return nil
    }

    func remove(channelKey: String, start: Date) {
        let id = ProgramReminder.key(channelKey, start)
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [Self.notificationPrefix + id])
        reminders.removeAll { $0.id == id }
        save()
    }

    /// Quita los avisos de programas que ya pasaron.
    func prune() {
        let cutoff = Date().addingTimeInterval(-3600)
        guard reminders.contains(where: { $0.start < cutoff }) else { return }
        reminders.removeAll { $0.start < cutoff }
        save()
    }

    /// Tras cambiar los minutos de antelación: reprograma los avisos pendientes.
    func reschedule() async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: reminders.map { Self.notificationPrefix + $0.id })
        for r in reminders where fireDate(r).timeIntervalSinceNow > 0 {
            try? await center.add(request(for: r))
        }
    }

    /// Al cerrar sesión (los ids de canal son de la cuenta).
    func clearAll() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: reminders.map { Self.notificationPrefix + $0.id })
        reminders = []
        save()
    }

    private func request(for r: ProgramReminder) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "\(r.title) empieza en \(Self.lead) min"
        content.body = r.channelName
        content.sound = .default
        content.userInfo = ["channel": r.channelKey]
        let delay = max(1, fireDate(r).timeIntervalSinceNow)
        return UNNotificationRequest(identifier: Self.notificationPrefix + r.id,
                                     content: content,
                                     trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false))
    }

    private func load() {
        guard let d = UserDefaults.standard.data(forKey: Self.storeKey),
              let list = try? JSONDecoder().decode([ProgramReminder].self, from: d) else { return }
        reminders = list.sorted { $0.start < $1.start }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(reminders) {
            UserDefaults.standard.set(d, forKey: Self.storeKey)
        }
    }
}
