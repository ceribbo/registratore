import Foundation
import Speech

enum Transcriber {
    struct Word {
        let time: Double
        let text: String
        let speaker: String
    }

    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// Trascrive separatamente microfono ("Io") e audio di sistema ("Altri"),
    /// poi unisce le parole per tempo in un dialogo.
    @MainActor
    static func transcribeConversation(tracks: [Track], locale: String) async throws -> String {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw RecorderError.speechDenied
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)),
              recognizer.isAvailable else {
            throw RecorderError.speechUnavailable
        }
        let onDevice = recognizer.supportsOnDeviceRecognition

        var words: [Word] = []
        var notes: [String] = []
        var dictationOff = 0
        for track in tracks {
            do {
                let raw = try await RecognitionCollector().run(recognizer: recognizer,
                                                               url: track.url,
                                                               onDevice: onDevice)
                words += raw.map { Word(time: $0.time + track.offset, text: $0.text, speaker: track.speaker) }
            } catch where isDictationDisabled(error) {
                dictationOff += 1
            } catch {
                notes.append("Traccia \"\(track.speaker)\" non trascritta: \(error.localizedDescription)")
            }
        }
        // Dettatura spenta: nessuna traccia può essere trascritta, inutile creare il file.
        if dictationOff > 0 && words.isEmpty {
            throw RecorderError.dictationDisabled
        }
        if dictationOff > 0 {
            notes.append("alcune tracce non sono state trascritte perché la Dettatura è disattivata.")
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: locale)

        var output = "Trascrizione del \(formatter.string(from: Date()))\n"
        if !onDevice {
            output += "Nota: modello locale non disponibile, usato il server Apple (le parti oltre il primo minuto circa possono mancare). Attiva la Dettatura in Impostazioni di Sistema > Tastiera per scaricare il modello locale.\n"
        }
        for note in notes { output += "Nota: \(note)\n" }
        output += "\n"
        output += words.isEmpty ? "(nessun parlato riconosciuto)\n" : format(words) + "\n"
        return output
    }

    /// Errore di Speech quando Siri/Dettatura sono disattivate nelle impostazioni di sistema.
    static func isDictationDisabled(_ error: Error) -> Bool {
        let text = (error as NSError).localizedDescription.lowercased()
        return text.contains("dictation") || text.contains("dettatura")
    }

    static func format(_ words: [Word]) -> String {
        let sorted = words.sorted { $0.time < $1.time }
        var lines: [String] = []
        var speaker: String?
        var start = 0.0
        var last = 0.0
        var buffer: [String] = []

        func flush() {
            if let speaker, !buffer.isEmpty {
                lines.append("[\(timestamp(start))] \(speaker): \(buffer.joined(separator: " "))")
            }
            buffer = []
        }

        for word in sorted {
            if word.speaker != speaker || word.time - last > 2.5 {
                flush()
                speaker = word.speaker
                start = word.time
            }
            buffer.append(word.text)
            last = word.time
        }
        flush()
        return lines.joined(separator: "\n\n")
    }

    static func timestamp(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

/// Raccoglie tutti i risultati finali di un task di riconoscimento su file.
final class RecognitionCollector: NSObject, SFSpeechRecognitionTaskDelegate {
    private var words: [(time: Double, text: String)] = []
    private var seen = Set<String>()
    private var continuation: CheckedContinuation<[(time: Double, text: String)], Error>?
    private var task: SFSpeechRecognitionTask?
    private var keepAlive: RecognitionCollector?

    func run(recognizer: SFSpeechRecognizer, url: URL, onDevice: Bool) async throws -> [(time: Double, text: String)] {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = onDevice

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.keepAlive = self
            self.task = recognizer.recognitionTask(with: request, delegate: self)
        }
    }

    func speechRecognitionTask(_ task: SFSpeechRecognitionTask,
                               didFinishRecognition result: SFSpeechRecognitionResult) {
        for segment in result.bestTranscription.segments {
            let key = "\(Int(segment.timestamp * 100))|\(segment.substring)"
            if seen.insert(key).inserted {
                words.append((segment.timestamp, segment.substring))
            }
        }
    }

    func speechRecognitionTask(_ task: SFSpeechRecognitionTask,
                               didFinishSuccessfully successfully: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        self.task = nil
        self.keepAlive = nil

        if successfully || !words.isEmpty {
            continuation.resume(returning: words)
            return
        }
        // Traccia senza parlato (es. call muta): non è un errore.
        if let error = task.error as NSError?,
           !(error.domain == "kAFAssistantErrorDomain" && [203, 1110].contains(error.code)) {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: [])
        }
    }
}
