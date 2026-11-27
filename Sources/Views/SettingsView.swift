import PhotosUI
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var engine: ScanEngine
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReset = false
    @State private var newKeyword = ""
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var refName = "Ich"
    @State private var refMessage: String?
    @State private var editCustom: CustomCategory?

    var body: some View {
        NavigationStack {
            Form {
                Section("Sicherheit") {
                    Toggle("Mit Face ID sperren", isOn: $engine.settings.appLock)
                    Toggle("Vorschaubilder unscharf", isOn: $engine.settings.blurPreviews)
                }

                Section {
                    ForEach(engine.settings.references) { r in Text(r.name) }
                        .onDelete { engine.settings.references.remove(atOffsets: $0) }
                    TextField("Name (z. B. Ich, Partnerin)", text: $refName)
                    PhotosPicker(selection: $pickerItems, maxSelectionCount: 10, matching: .images) {
                        Label("Fotos mit diesem Gesicht wählen", systemImage: "person.crop.square.badge.plus")
                    }
                    if let refMessage { Text(refMessage).font(.caption).foregroundStyle(.secondary) }
                    slider("Ähnlichkeit (Abstand)", value: $engine.settings.t.faceMatchDistance, range: 0.2...1.2, pct: false)
                    Toggle("Körper ohne Gesicht als „andere Person“", isOn: $engine.settings.facelessCountsAsOther)
                } header: {
                    Text("Bekannte Personen")
                } footer: {
                    Text("3–10 klare Porträts je Person. Gesichter, die keiner bekannten Person ähneln, landen in „Andere Personen“. Grober Bildvergleich, keine echte Gesichtserkennung – Abstand nach Gefühl anpassen.")
                }

                Section {
                    ForEach(engine.settings.keywords, id: \.self) { Text($0) }
                        .onDelete { engine.settings.keywords.remove(atOffsets: $0) }
                    HStack {
                        TextField("Neues Stichwort", text: $newKeyword)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Hinzufügen") {
                            let k = newKeyword.trimmingCharacters(in: .whitespaces).lowercased()
                            if !k.isEmpty && !engine.settings.keywords.contains(k) { engine.settings.keywords.append(k) }
                            newKeyword = ""
                        }
                    }
                } header: {
                    Text("Stichwörter für Chats & Screenshots")
                } footer: {
                    Text("Gesucht wird im Text, der aus Screenshots und empfangenen Bildern gelesen wurde. Änderungen wirken ohne Neu-Scan.")
                }

                Section {
                    slider("Mann/Frau ab Anteil", value: $engine.settings.t.genderShare, range: 0.5...0.95)
                    slider("Person mindestens", value: $engine.settings.t.genderMinPerson, range: 0.05...0.8)
                } header: {
                    Text("Frauen / Männer")
                } footer: {
                    Text(engine.clip.isAvailable
                         ? "Apples MobileCLIP schätzt lokal nach Aussehen ein. Paarfotos landen in beiden Kategorien. Fehleinschätzungen sind möglich."
                         : "MobileCLIP ist in diesem Build nicht enthalten.")
                }

                Section {
                    Toggle("Nur Treffer mit Frauen", isOn: $engine.settings.womenOnly)
                } header: {
                    Text("Filter")
                } footer: {
                    Text("Gilt für „Freizügig“, „Andere Personen“ und „Social-Media-Speicherungen“. Entschieden wird mit MobileCLIP, nach der Feinprüfung mit Apple Intelligence. Fehleinschätzungen sind möglich.")
                }

                Section {
                    ForEach(engine.settings.socialMarkers, id: \.self) { Text($0) }
                        .onDelete { engine.settings.socialMarkers.remove(atOffsets: $0) }
                    Toggle("Videos mitscannen", isOn: $engine.settings.includeVideos)
                } header: {
                    Text("Social-Media-Speicherungen")
                } footer: {
                    Text("Erkannt an Wasserzeichen-Text (z. B. TikTok-Logo, @Benutzername) in Bildern ohne Kamera-Daten, oder an Hochformat-Videos ohne Kamera-Daten. Bei Videos werden 3 Einzelbilder geprüft.")
                }

                Section {
                    ForEach(engine.settings.custom) { c in
                        Button { editCustom = c } label: {
                            VStack(alignment: .leading) {
                                Text(c.name)
                                Text(c.question).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    .onDelete { idx in
                        for i in idx { engine.clearLLMAnswers(for: engine.settings.custom[i].id.uuidString) }
                        engine.settings.custom.remove(atOffsets: idx)
                    }
                    Button("Kategorie hinzufügen", systemImage: "plus") {
                        editCustom = CustomCategory(name: "", question: "")
                    }
                    Toggle("Alle Fotos prüfen (sehr langsam)", isOn: $engine.settings.llmAllPhotos)
                    Toggle("Treffer gegenprüfen", isOn: $engine.settings.llmVerify)
                } header: {
                    Text("Apple Intelligence (auf dem Gerät)")
                } footer: {
                    Text(LLMJudge.statusText + ". Ohne „Alle Fotos“ werden nur Bilder mit Menschen, Screenshots und empfangene Bilder geprüft.")
                }

                Section("Menschen-Erkennung") {
                    slider("Mindest-Score", value: $engine.settings.t.minScore, range: 0.2...0.95)
                    Stepper("Mindestens \(engine.settings.t.minJoints) Gelenke", value: $engine.settings.t.minJoints, in: 1...10)
                    slider("Personenfläche", value: $engine.settings.t.minMaskCoverage, range: 0.01...0.3)
                    slider("Label-Sicherheit", value: $engine.settings.t.minLabelConfidence, range: 0.05...0.9)
                    slider("Freizügig ab", value: $engine.settings.t.revealingLabel, range: 0.05...0.9)
                }

                Section("Nacktbilder") {
                    Text(engine.nudity.statusText).font(.footnote)
                    if engine.nudity.fallbackAvailable {
                        slider("Ersatzmodell nackt ab", value: $engine.settings.t.nsfwModel, range: 0.3...0.99)
                        slider("Ersatzmodell freizügig ab", value: $engine.settings.t.sexyModel, range: 0.3...0.99)
                    }
                }

                Section("Scan") {
                    Toggle("iCloud-Originale laden", isOn: $engine.settings.allowICloud)
                    Stepper("Parallel: \(engine.settings.concurrency)", value: $engine.settings.concurrency, in: 1...6)
                    Button("Scan-Ergebnisse löschen", role: .destructive) { confirmReset = true }
                }
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Fertig") { dismiss() } }
            .confirmationDialog("Alle Scan-Ergebnisse löschen?", isPresented: $confirmReset) {
                Button("Löschen", role: .destructive) { engine.resetCache() }
            }
            .onChange(of: pickerItems) { _, items in Task { await addReferences(items) } }
            .sheet(item: $editCustom) { c in
                CustomCategoryEditor(category: c) { saved in
                    if let i = engine.settings.custom.firstIndex(where: { $0.id == saved.id }) {
                        if engine.settings.custom[i].question != saved.question {
                            engine.clearLLMAnswers(for: saved.id.uuidString)
                        }
                        engine.settings.custom[i] = saved
                    } else {
                        engine.settings.custom.append(saved)
                    }
                }
            }
        }
    }

    private func addReferences(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        var added = 0
        let name = refName.trimmingCharacters(in: .whitespaces).isEmpty ? "Person" : refName
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let cg = ImageLoader.cgImage(from: data),
                  let print = PersonAnalyzer.referencePrint(from: cg) else { continue }
            engine.settings.references.append(ReferenceFace(name: "\(name) \(added + 1)", print: print))
            added += 1
        }
        refMessage = "\(added) von \(items.count) Fotos übernommen" + (added < items.count ? " (kein Gesicht erkannt)" : "")
        pickerItems = []
    }

    private func slider(_ title: String, value: Binding<Float>, range: ClosedRange<Float>, pct: Bool = true) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title); Spacer()
                Text(pct ? "\(Int(value.wrappedValue * 100)) %" : String(format: "%.2f", value.wrappedValue))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }
}

struct CustomCategoryEditor: View {
    @State var category: CustomCategory
    let onSave: (CustomCategory) -> Void
    @Environment(\.dismiss) private var dismiss

    private let examples = [
        ("Bars & Partys", "Wurde das Foto in einer Bar, einem Club oder auf einer Party aufgenommen?"),
        ("Selfies mit anderen", "Ist es ein Selfie, auf dem mehr als eine Person zu sehen ist?"),
        ("Hotel & Übernachtung", "Wurde das Foto in einem Hotelzimmer oder Schlafzimmer aufgenommen?")
    ]

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $category.name)
                TextField("Ja/Nein-Frage an das Bild", text: $category.question, axis: .vertical)
                    .lineLimit(2...5)
                Section("Beispiele") {
                    ForEach(examples, id: \.0) { e in
                        Button(e.0) { category.name = e.0; category.question = e.1 }
                    }
                }
            }
            .navigationTitle("Eigene Kategorie")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") { onSave(category); dismiss() }
                        .disabled(category.name.isEmpty || category.question.isEmpty)
                }
            }
        }
    }
}
