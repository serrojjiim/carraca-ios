import SwiftUI
import StoreKit

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
