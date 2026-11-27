import SwiftUI

struct HomeView: View {
    @EnvironmentObject var engine: ScanEngine
    @AppStorage("scope") private var scope: ScanScope = .all
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    privacyBanner
                    scanCard
                    refineCard
                    VStack(spacing: 0) {
                        ForEach(engine.allBuckets) { b in
                            NavigationLink(value: b) { BucketRow(bucket: b) }
                                .buttonStyle(.plain)
                                .disabled(engine.count(b) == 0)
                            Divider().padding(.leading, 70)
                        }
                    }
                    .background(.background, in: RoundedRectangle(cornerRadius: 18))
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Ablage")
            .navigationDestination(for: Bucket.self) { ResultsGridView(bucket: $0) }
            .toolbar {
                Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                    .accessibilityLabel("Einstellungen")
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }

    private var privacyBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.iphone").font(.title2).foregroundStyle(.green)
            Text("Alles wird nur auf diesem iPhone analysiert – auch Apple Intelligence läuft lokal.")
                .font(.footnote).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    private var busy: Bool { engine.phase == .scanning || engine.phase == .refining }

    private var scanCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("1 · Schneller Scan").font(.headline)
            Picker("Bereich", selection: $scope) {
                ForEach(ScanScope.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(busy)

            if !engine.nudity.appleAvailable {
                Label(engine.nudity.statusText, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            if engine.phase == .scanning {
                progress
            } else {
                Button { engine.start(scope: scope) } label: {
                    Label(engine.results.isEmpty ? "Scan starten" : "Neue Fotos scannen", systemImage: "sparkle.magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(busy)
            }
            if engine.phase == .needsAccess {
                Text("Bitte vollen Fotozugriff in den Einstellungen erlauben.").font(.caption).foregroundStyle(.red)
            }
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    private var refineCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("2 · Feinprüfung mit Apple Intelligence").font(.headline)
            Text(LLMJudge.statusText).font(.caption).foregroundStyle(.secondary)
            if engine.phase == .refining {
                progress
            } else {
                Button { engine.refine() } label: {
                    Label("\(engine.refineCandidates.count) Kandidaten prüfen", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).controlSize(.large)
                .disabled(busy || !LLMJudge.isAvailable || engine.results.isEmpty)
            }
            Text("Senkt Fehlalarme und füllt deine eigenen Kategorien. Dauert ein paar Sekunden pro Bild.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: Double(engine.processed), total: Double(max(engine.total, 1)))
            HStack {
                Text("\(engine.processed) von \(engine.total)").font(.caption.monospacedDigit())
                Spacer()
                Button("Abbrechen", role: .destructive) { engine.cancel() }.font(.caption)
            }
        }
    }
}

struct BucketRow: View {
    @EnvironmentObject var engine: ScanEngine
    let bucket: Bucket

    private var symbol: String {
        if case .builtin(let c) = bucket { return c.symbol }
        return "text.magnifyingglass"
    }
    private var subtitle: String {
        if case .builtin(let c) = bucket { return c.subtitle }
        return "Eigene Kategorie · Apple Intelligence"
    }
    private var tint: Color {
        switch bucket {
        case .builtin(.nude), .builtin(.revealing): return .pink
        case .custom: return .teal
        default: return .indigo
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 42, height: 42)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 11))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.title(bucket)).font(.body.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(engine.count(bucket))").font(.headline.monospacedDigit())
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}
