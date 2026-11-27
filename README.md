# Ablage (Fotosortierer)

iOS-App, die die Fotomediathek **nur auf dem Gerät** analysiert und Treffer in Kategorien vorschlägt.
Aus den Vorschlägen auswählen → in Album verschieben, ignorieren oder aus der Mediathek löschen.

## Ablauf
1. **Schneller Scan** (alle Fotos): Apple SensitiveContentAnalysis, Vision (Personen, Pose, Hände,
   Segmentierung, Labels, Gesichts-Prints), OCR für Screenshots/empfangene Bilder, EXIF-Kamera-Check.
2. **Feinprüfung** (nur Kandidaten): Apple Foundation Models auf dem Gerät (iOS 27, Apple Intelligence),
   Ja/Nein-Fragen je Kategorie. Niemals Private Cloud Compute.

## Kategorien
Mögliche Nacktbilder · Freizügig · Andere Personen (gegen Referenzgesichter) ·
Chats & App-Screenshots (Stichwörter + Feinprüfung) · Social-Media-Speicherungen (TikTok-Wasserzeichen,
Hochformat-Videos) · Empfangen · eigene Kategorien per Frage. Optionaler Filter „nur Frauen“ (Apple Intelligence).
Videos: 3 Einzelbilder je Clip (10/50/90 %).

## Bauen
- `xcodegen generate`, dann mit **Xcode 27 / iOS-27-SDK** bauen (für FoundationModels mit Bildern).
  Mit älterem SDK baut es auch, die Feinprüfung ist dann aus.
- ⚠️ `Sources/Analysis/LLMJudge.swift`: Bildanhang im Prompt (`Attachment(image)`) gegen das echte
  iOS-27-SDK prüfen – der genaue Typname war nicht dokumentiert.
- Optional: `NSFW.mlmodelc` (Core-ML-Klassifizierer) ins Bundle legen = Ersatz, falls die
  SensitiveContentAnalysis-Berechtigung beim Sideloaden nicht greift.

## Voraussetzungen am iPhone
- Einstellungen › Datenschutz & Sicherheit › **Hinweis auf sensible Inhalte** ein
- **Apple Intelligence** ein und Modell fertig geladen
- Voller Fotozugriff
