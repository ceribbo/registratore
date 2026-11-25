import SwiftUI
import AppKit

@main
struct RegistratoreApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var recorder = Recorder()

    var body: some Scene {
        // Finestra principale: si apre all'avvio e cliccando l'icona nel Dock
        Window("Registratore", id: "main") {
            RootView()
                .environmentObject(recorder)
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            RootView()
                .environmentObject(recorder)
        } label: {
            Image(systemName: recorder.isRecording ? "record.circle.fill" : "waveform.circle")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Chiudendo la finestra l'app resta attiva (nel Dock e nella barra dei menu)
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Mostra l'avviso sull'uso responsabile finché non viene accettato, poi l'interfaccia.
struct RootView: View {
    @AppStorage("avvisoUsoResponsabileAccettato") private var accepted = false

    var body: some View {
        if accepted {
            ContentView()
        } else {
            DisclaimerView { accepted = true }
        }
    }
}

struct DisclaimerView: View {
    let onAccept: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Prima di iniziare", systemImage: "exclamationmark.shield")
                .font(.headline)

            Text("Registrare una conversazione può essere soggetto a limiti di legge, che cambiano da Paese a Paese. In alcuni Paesi serve il consenso di tutti i partecipanti.")
                .fixedSize(horizontal: false, vertical: true)

            Text("Sei responsabile di come usi l'app: rispetta le leggi applicabili, informa gli altri partecipanti e chiedi il loro consenso quando necessario, e non diffondere le registrazioni senza averne diritto.")
                .fixedSize(horizontal: false, vertical: true)

            Text("Registrazioni e trascrizioni restano sul tuo Mac. Se il modello di dettatura locale non è installato, la trascrizione usa i server Apple.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Esci") { NSApp.terminate(nil) }
                Spacer()
                Button("Ho capito, continua", action: onAccept)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 300)
    }
}

struct ContentView: View {
    @EnvironmentObject var recorder: Recorder

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Registratore").font(.headline)

            switch recorder.state {
            case .idle:
                Button {
                    Task { await recorder.start() }
                } label: {
                    Label("Avvia registrazione", systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!recorder.hasSource)

            case .recording(let start):
                HStack {
                    Circle().fill(.red).frame(width: 10, height: 10)
                    Text(start, style: .timer)
                        .font(.system(.title2, design: .monospaced))
                }
                Button {
                    Task { await recorder.stop() }
                } label: {
                    Label("Ferma", systemImage: "stop.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)

            case .busy(let text):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(text)
                }
            }

            SourcesView()
                .disabled(recorder.state != .idle)

            Divider()

            Toggle("Trascrivi a fine registrazione", isOn: $recorder.transcribe)
                .disabled(recorder.state != .idle)

            Picker("Lingua", selection: $recorder.language) {
                Text("Italiano").tag("it-IT")
                Text("English").tag("en-US")
            }
            .disabled(recorder.state != .idle)

            if let message = recorder.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if recorder.needsDictation {
                    Button("Apri impostazioni Dettatura") { recorder.openDictationSettings() }
                }
            }

            Divider()

            HStack {
                Button("Apri registrazioni") { recorder.openFolder() }
                Spacer()
                Button("Esci") { NSApp.terminate(nil) }
            }
        }
        .padding()
        .frame(width: 300)
    }
}

// MARK: - Selezione delle fonti

struct SourcesView: View {
    @EnvironmentObject var recorder: Recorder

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Fonti").font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    recorder.refreshSources()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Aggiorna l'elenco di microfoni e app")
            }

            Toggle(isOn: $recorder.useMicrophone) {
                Label("Microfono", systemImage: "mic")
            }
            Picker("Dispositivo", selection: $recorder.microphoneUID) {
                Text("Predefinito di sistema").tag("")
                ForEach(recorder.microphones) { mic in
                    Text(mic.name).tag(mic.uid)
                }
            }
            .labelsHidden()
            .disabled(!recorder.useMicrophone)

            Toggle(isOn: $recorder.useSystemAudio) {
                Label("Audio del Mac", systemImage: "speaker.wave.2")
            }
            Picker("App", selection: $recorder.systemAppBundleID) {
                Text("Tutte le app").tag("")
                ForEach(recorder.apps) { app in
                    Text(app.name).tag(app.bundleID)
                }
            }
            .labelsHidden()
            .disabled(!recorder.useSystemAudio)

            if !recorder.hasSource {
                Text("Seleziona almeno una fonte.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onAppear { recorder.refreshSources() }
    }
}
