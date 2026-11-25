import Foundation
import AVFoundation
import AppKit
import CoreGraphics

enum RecorderError: LocalizedError {
    case noDisplay, noMicrophone, microphoneUnavailable, appNotRunning, export, speechDenied, speechUnavailable, dictationDisabled

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "Nessuno schermo disponibile per la cattura audio."
        case .noMicrophone: return "Nessun microfono disponibile."
        case .microphoneUnavailable: return "Il microfono selezionato non è disponibile. Scegline un altro."
        case .appNotRunning: return "L'app selezionata non è in esecuzione. Aprila o scegli \"Tutte le app\"."
        case .export: return "Esportazione del mix non riuscita."
        case .speechDenied: return "Permesso di riconoscimento vocale negato (Impostazioni di Sistema > Privacy e sicurezza > Riconoscimento vocale)."
        case .speechUnavailable: return "Riconoscimento vocale non disponibile per questa lingua."
        case .dictationDisabled: return "La Dettatura di macOS è disattivata, quindi la trascrizione non è possibile. Attivala in Impostazioni di Sistema > Tastiera > Dettatura, poi riprova. L'audio è stato salvato comunque."
        }
    }
}

struct Track {
    let url: URL
    let offset: Double
    let speaker: String
}

@MainActor
final class Recorder: ObservableObject {
    enum State: Equatable {
        case idle
        case recording(Date)
        case busy(String)
    }

    @Published private(set) var state: State = .idle {
        didSet { NSApp?.dockTile.badgeLabel = isRecording ? "REC" : nil }
    }
    @Published var message: String?
    @Published var transcribe: Bool {
        didSet { UserDefaults.standard.set(transcribe, forKey: "transcribe") }
    }
    @Published var language: String {
        didSet { UserDefaults.standard.set(language, forKey: "language") }
    }
    @Published private(set) var lastSession: URL?
    /// Vero se l'ultima trascrizione è fallita perché la Dettatura è disattivata.
    @Published private(set) var needsDictation = false

    // Fonti
    @Published var useMicrophone: Bool {
        didSet { UserDefaults.standard.set(useMicrophone, forKey: "useMicrophone") }
    }
    /// UID del dispositivo; stringa vuota = microfono predefinito di sistema.
    @Published var microphoneUID: String {
        didSet { UserDefaults.standard.set(microphoneUID, forKey: "microphoneUID") }
    }
    @Published var useSystemAudio: Bool {
        didSet { UserDefaults.standard.set(useSystemAudio, forKey: "useSystemAudio") }
    }
    /// Bundle ID dell'app da registrare; stringa vuota = tutto l'audio del Mac.
    @Published var systemAppBundleID: String {
        didSet { UserDefaults.standard.set(systemAppBundleID, forKey: "systemAppBundleID") }
    }
    @Published private(set) var microphones: [MicrophoneSource] = []
    @Published private(set) var apps: [AppSource] = []

    private var mic: MicrophoneCapture?
    private var system: SystemAudioCapture?
    private var micWriter: AudioFileWriter?
    private var systemWriter: AudioFileWriter?
    private var sessionFolder: URL?

    let rootFolder: URL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Registratore", isDirectory: true)

    init() {
        let defaults = UserDefaults.standard
        transcribe = defaults.object(forKey: "transcribe") as? Bool ?? true
        language = defaults.string(forKey: "language") ?? "it-IT"
        useMicrophone = defaults.object(forKey: "useMicrophone") as? Bool ?? true
        microphoneUID = defaults.string(forKey: "microphoneUID") ?? ""
        useSystemAudio = defaults.object(forKey: "useSystemAudio") as? Bool ?? true
        systemAppBundleID = defaults.string(forKey: "systemAppBundleID") ?? ""
        refreshSources()
    }

    /// Aggiorna l'elenco di microfoni e app. Le scelte salvate restano in elenco
    /// anche se al momento non sono disponibili, così il menu le mostra.
    func refreshSources() {
        var mics = AudioSources.microphones()
        if !microphoneUID.isEmpty, !mics.contains(where: { $0.uid == microphoneUID }) {
            mics.append(MicrophoneSource(uid: microphoneUID, name: "Microfono non collegato"))
        }
        microphones = mics

        var running = AudioSources.runningApps()
        if !systemAppBundleID.isEmpty, !running.contains(where: { $0.bundleID == systemAppBundleID }) {
            running.append(AppSource(bundleID: systemAppBundleID, name: "\(systemAppBundleID) (chiusa)"))
        }
        apps = running
    }

    var hasSource: Bool { useMicrophone || useSystemAudio }

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    // MARK: - Avvio

    func start() async {
        guard state == .idle else { return }
        guard hasSource else {
            message = "Seleziona almeno una fonte da registrare."
            return
        }
        message = nil
        needsDictation = false
        state = .busy("Avvio...")

        var micDevice: AudioDeviceID?
        if useMicrophone {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                fail("Accesso al microfono negato. Abilitalo in Impostazioni di Sistema > Privacy e sicurezza > Microfono.")
                return
            }
            if !microphoneUID.isEmpty {
                guard let id = AudioSources.deviceID(forUID: microphoneUID) else {
                    fail(RecorderError.microphoneUnavailable.localizedDescription)
                    return
                }
                micDevice = id
            }
        }

        if useSystemAudio, !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
            fail("Per catturare l'audio delle call serve il permesso \"Registrazione schermo e audio di sistema\" (Impostazioni di Sistema > Privacy e sicurezza). Abilitalo, poi chiudi e riapri l'app.")
            return
        }

        if transcribe {
            _ = await Transcriber.requestAuthorization()
        }

        let folder: URL
        do {
            folder = try makeSessionFolder()
        } catch {
            fail("Impossibile creare la cartella: \(error.localizedDescription)")
            return
        }

        // Tracce separate temporanee: servono per il mix e la trascrizione, poi vengono eliminate
        let tracksFolder = folder.appendingPathComponent(".tracce", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tracksFolder, withIntermediateDirectories: true)
        } catch {
            fail("Impossibile creare la cartella: \(error.localizedDescription)")
            return
        }
        let micW = AudioFileWriter(url: tracksFolder.appendingPathComponent("voce.m4a"))
        let sysW = AudioFileWriter(url: tracksFolder.appendingPathComponent("call.m4a"))

        var sys: SystemAudioCapture?
        if useSystemAudio {
            let capture = SystemAudioCapture(writer: sysW,
                                             appBundleID: systemAppBundleID.isEmpty ? nil : systemAppBundleID)
            capture.onError = { [weak self] error in
                Task { @MainActor in
                    self?.message = "Cattura audio del Mac interrotta: \(error.localizedDescription)"
                }
            }
            do {
                try await capture.start()
            } catch {
                Self.removeEmptySession(folder)
                fail("Cattura audio del Mac non avviata: \(error.localizedDescription)")
                return
            }
            sys = capture
        }

        var m: MicrophoneCapture?
        if useMicrophone {
            let capture = MicrophoneCapture(writer: micW, deviceID: micDevice)
            do {
                try capture.start()
            } catch {
                await sys?.stop()
                Self.removeEmptySession(folder)
                fail("Microfono non avviato: \(error.localizedDescription)")
                return
            }
            m = capture
        }

        mic = m
        system = sys
        micWriter = micW
        systemWriter = sysW
        sessionFolder = folder
        state = .recording(Date())
    }

    // MARK: - Stop, mix e trascrizione

    func stop() async {
        guard isRecording,
              let folder = sessionFolder,
              let micW = micWriter,
              let sysW = systemWriter else { return }

        state = .busy("Chiusura file...")
        mic?.stop()
        await system?.stop()
        micW.close()
        sysW.close()
        mic = nil
        system = nil
        micWriter = nil
        systemWriter = nil
        sessionFolder = nil

        let tracks = Self.tracks(mic: micW, system: sysW)
        guard !tracks.isEmpty else {
            Self.cleanUpTracks(in: folder, keep: false)
            fail("Nessun audio registrato.")
            return
        }

        state = .busy("Creo il mix...")
        var mixed = false
        do {
            try await AudioMixer.mix(tracks, to: folder.appendingPathComponent("registrazione.m4a"))
            mixed = true
        } catch {
            message = "Mix non riuscito: \(error.localizedDescription). Ho tenuto le tracce separate."
        }

        if transcribe {
            state = .busy("Trascrivo... (può richiedere qualche minuto)")
            do {
                let text = try await Transcriber.transcribeConversation(tracks: tracks, locale: language)
                try text.write(to: folder.appendingPathComponent("trascrizione.txt"),
                               atomically: true, encoding: .utf8)
            } catch RecorderError.dictationDisabled {
                needsDictation = true
                message = RecorderError.dictationDisabled.localizedDescription
            } catch {
                message = "Trascrizione non riuscita: \(error.localizedDescription)"
            }
        }

        Self.cleanUpTracks(in: folder, keep: !mixed)

        lastSession = folder
        state = .idle
        if message == nil {
            message = "Salvata in \"\(folder.lastPathComponent)\"."
        }
    }

    // MARK: - Utilità

    func openDictationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func openFolder() {
        try? FileManager.default.createDirectory(at: rootFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(lastSession ?? rootFolder)
    }

    private func fail(_ text: String) {
        message = text
        state = .idle
    }

    private func makeSessionFolder() throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let folder = rootFolder.appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Rimuove la cartella di una sessione che non è partita.
    private static func removeEmptySession(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Elimina le tracce separate; se il mix non è riuscito le sposta nella cartella della sessione.
    private static func cleanUpTracks(in folder: URL, keep: Bool) {
        let fm = FileManager.default
        let tracksFolder = folder.appendingPathComponent(".tracce", isDirectory: true)
        if keep, let files = try? fm.contentsOfDirectory(at: tracksFolder, includingPropertiesForKeys: nil) {
            for file in files {
                try? fm.moveItem(at: file, to: folder.appendingPathComponent(file.lastPathComponent))
            }
        }
        try? fm.removeItem(at: tracksFolder)
    }

    /// Allinea le due tracce usando l'orario del primo campione di ciascuna.
    private static func tracks(mic: AudioFileWriter, system: AudioFileWriter) -> [Track] {
        let active = [(mic, "Io"), (system, "Altri")].filter { $0.0.framesWritten > 0 }
        let starts = active.compactMap { $0.0.firstHostSeconds }
        let base = starts.min() ?? 0
        let spread = (starts.max() ?? 0) - base
        return active.map { writer, speaker in
            var offset = 0.0
            if let first = writer.firstHostSeconds, spread < 10 {
                offset = first - base
            }
            return Track(url: writer.url, offset: offset, speaker: speaker)
        }
    }
}
