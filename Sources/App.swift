import LocalAuthentication
import SwiftUI

@main
struct FotoSortiererApp: App {
    @StateObject private var engine = ScanEngine()
    @StateObject private var lock = AppLock()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ZStack {
                HomeView()
                    .environmentObject(engine)
                    .tint(.indigo)
                // Deckblatt: im App-Umschalter und solange gesperrt nichts sichtbar
                if lock.locked || scenePhase != .active {
                    LockCover(lock: lock)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                // Nur nach echtem Hintergrund neu sperren – der Face-ID-Dialog selbst
                // macht die App nur „inactive“, sonst gäbe es eine Abfrage-Schleife.
                if phase == .background && engine.settings.appLock {
                    lock.locked = true
                    lock.promptOnActive = true
                }
                if phase == .active && lock.promptOnActive {
                    lock.promptOnActive = false
                    lock.unlock()
                }
            }
            .onAppear {
                if engine.settings.appLock { lock.unlock() } else { lock.locked = false }
            }
        }
    }
}

@MainActor
final class AppLock: ObservableObject {
    @Published var locked = true
    @Published var failed = false
    var promptOnActive = false
    private var busy = false

    func unlock() {
        guard locked, !busy else { return }
        busy = true
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Code eingeben"
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Ablage entsperren") { ok, _ in
            Task { @MainActor in
                self.busy = false
                self.locked = !ok
                self.failed = !ok
            }
        }
    }
}

struct LockCover: View {
    @ObservedObject var lock: AppLock
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "archivebox.fill").font(.system(size: 52)).foregroundStyle(.secondary)
                Text("Ablage").font(.title2.bold())
                if lock.locked {
                    Button { lock.unlock() } label: { Label("Entsperren", systemImage: "faceid") }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}
