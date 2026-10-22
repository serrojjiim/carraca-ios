import SwiftUI
import StoreKit

/// Suscripción "Carraca Premium" (solo versión App Store / TestFlight; la privada es gratis).
/// Mensual 0,99 € y anual 9,99 €, las dos con 3 días de prueba gratis (oferta introductoria de Apple).
/// Los códigos de regalo son códigos de oferta de Apple: se canjean aquí o con el enlace de la App Store.
@MainActor
final class Store: ObservableObject {
    static let productIDs = ["com.carraca.smarter.premium.mensual", "com.carraca.smarter.premium.anual"]
    static let eulaURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    /// Interruptor de la suscripción. En false la app es gratis para todos: no se pide pago, no se
    /// consulta StoreKit y Ajustes no enseña "Suscripción". Para activarla en el futuro: true +
    /// productos creados en App Store Connect (acuerdo de apps de pago firmado) + enviarlos con la versión.
    static let paywallEnabled = false

    @Published private(set) var products: [Product] = []
    @Published private(set) var isPremium = false
    /// Hasta comprobar las compras no se enseña ni la app ni la pantalla de pago.
    @Published private(set) var checked = false
    @Published private(set) var trialEligible = true
    @Published private(set) var loadFailed = false
    @Published private(set) var expiration: Date?
    @Published private(set) var willRenew = true

    private var updates: Task<Void, Never>?

    /// Build de TestFlight (recibo de sandbox).
    static let isTestFlight = Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"

    /// Solo TestFlight y solo mientras los planes no existen en App Store Connect:
    /// deja entrar para poder probar el resto de la app. En la App Store nunca aplica.
    var testFlightBypass: Bool { Store.isTestFlight && products.isEmpty && loadFailed }

    init() {
        if Flavor.isPrivate || !Store.paywallEnabled {
            isPremium = true
            checked = true
            return
        }
        // Compras hechas fuera de la app (renovaciones, códigos canjeados en la App Store, Ajustes…).
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let t) = result { await t.finish() }
                await self?.refresh()
            }
        }
        Task {
            await refresh()
            await loadProducts()
        }
    }

    deinit { updates?.cancel() }

    func loadProducts() async {
        guard !Flavor.isPrivate else { return }
        do {
            let list = try await Product.products(for: Self.productIDs)
            products = list.sorted { $0.price < $1.price }
            loadFailed = products.isEmpty
            if let sub = products.first?.subscription {
                trialEligible = await sub.isEligibleForIntroOffer
            }
        } catch {
            loadFailed = true
        }
    }

    func refresh() async {
        guard !Flavor.isPrivate else { return }
        var active = false
        var exp: Date?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let t) = result, Self.productIDs.contains(t.productID), t.revocationDate == nil else { continue }
            if let e = t.expirationDate, e < Date() { continue }
            active = true
            if let e = t.expirationDate, exp == nil || e > exp! { exp = e }
        }
        isPremium = active
        expiration = exp
        if active, let sub = products.first?.subscription,
           let status = try? await sub.status.first(where: { $0.state == .subscribed || $0.state == .inGracePeriod }),
           case .verified(let info) = status.renewalInfo {
            willRenew = info.willAutoRenew
        }
        checked = true
    }

    /// true si la compra se ha completado.
    func buy(_ product: Product) async throws -> Bool {
        switch try await product.purchase() {
        case .success(let verification):
            guard case .verified(let t) = verification else { return false }
            await t.finish()
            await refresh()
            return isPremium
        default:
            return false
        }
    }

    func restore() async {
        try? await AppStore.sync()
        await refresh()
    }

    /// Hoja de Apple para canjear un código de regalo.
    func redeemCode() async {
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else { return }
        try? await AppStore.presentOfferCodeRedeemSheet(in: scene)
        await refresh()
    }
}

extension Product {
    var isYearly: Bool { subscription?.subscriptionPeriod.unit == .year }
    var periodText: String { isYearly ? "año" : "mes" }
}

// MARK: - Pantalla de suscripción

struct PaywallView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var session: Session
    @State private var selected: Product.ID?
    @State private var busy = false
    @State private var error: String?

    private var chosen: Product? {
        store.products.first { $0.id == selected } ?? store.products.first(where: \.isYearly) ?? store.products.first
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 90)
                    .padding(.top, 40)
                Text("Carraca Premium").font(.largeTitle.bold())
                Text(store.trialEligible ? "Pruébala gratis 3 días. Cancela cuando quieras." : "Suscríbete para seguir usando Carraca.")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: 10) {
                    feature("tv", "Canales en directo con vista previa y guía")
                    feature("film", "Películas y series con audio y subtítulos")
                    feature("clock.arrow.circlepath", "Sigue viendo donde lo dejaste")
                    feature("ipad.and.iphone", "iPhone, iPad y Mac con la misma suscripción")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if store.products.isEmpty {
                    if store.loadFailed {
                        VStack(spacing: 10) {
                            Text("No se han podido cargar los planes.").foregroundStyle(.secondary)
                            Button("Reintentar") { Task { await store.loadProducts() } }.buttonStyle(.bordered)
                        }
                    } else {
                        ProgressView()
                    }
                } else {
                    VStack(spacing: 12) {
                        ForEach(store.products) { p in planCard(p) }
                    }
                }

                if let error {
                    Text(error).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
                }

                Button {
                    Task { await purchase() }
                } label: {
                    HStack(spacing: 10) {
                        if busy { ProgressView().tint(.white) }
                        Text(store.trialEligible ? "Empezar prueba gratis" : "Suscribirme").bold()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(busy || chosen == nil)

                if let p = chosen {
                    Text(legal(p))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 22) {
                    Button("Restaurar compras") { Task { busy = true; await store.restore(); busy = false } }
                    Button("Tengo un código") { Task { await store.redeemCode() } }
                }
                .font(.subheadline)

                HStack(spacing: 22) {
                    Link("Condiciones de uso", destination: Store.eulaURL)
                    Link("Privacidad", destination: URL(string: AppConfig.panel + "/ios/privacidad.html")!)
                }
                .font(.caption)

                Button("Cerrar sesión", role: .destructive) { session.logout() }
                    .font(.footnote)
                    .padding(.top, 4)
            }
            .padding(24)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .background(Color("LaunchBg").ignoresSafeArea())
    }

    private func feature(_ icon: String, _ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: icon).foregroundStyle(Color.accentColor).frame(width: 26)
        }
    }

    private func planCard(_ p: Product) -> some View {
        let on = p.id == chosen?.id
        return Button { selected = p.id } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(p.isYearly ? "Anual" : "Mensual").font(.headline)
                        if p.isYearly, let s = saving { TagChip(text: "Ahorra \(s)%") }
                    }
                    Text("\(p.displayPrice) / \(p.periodText)").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(on ? Color.accentColor : .secondary)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(on ? 0.12 : 0.06)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(on ? Color.accentColor : .clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// % que se ahorra con el anual frente a 12 meses del mensual.
    private var saving: Int? {
        guard let m = store.products.first(where: { !$0.isYearly }), let y = store.products.first(where: \.isYearly) else { return nil }
        let year = NSDecimalNumber(decimal: m.price * 12).doubleValue
        let annual = NSDecimalNumber(decimal: y.price).doubleValue
        guard year > 0, annual < year else { return nil }
        return Int(((year - annual) / year * 100).rounded())
    }

    private func legal(_ p: Product) -> String {
        let trial = store.trialEligible ? "Tras los 3 días gratis se cobran " : "Se cobran "
        return trial + "\(p.displayPrice) cada \(p.periodText) a tu Apple ID. La suscripción se renueva sola salvo que la canceles al menos 24 horas antes de que termine el periodo, en Ajustes > tu nombre > Suscripciones."
    }

    private func purchase() async {
        guard let p = chosen else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            _ = try await store.buy(p)
        } catch {
            self.error = "No se ha podido completar la compra. Inténtalo de nuevo."
        }
    }
}
