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
