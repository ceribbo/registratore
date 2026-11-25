import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import CoreAudio
import AudioToolbox

// MARK: - Scrittura su file (AAC .m4a), thread safe

final class AudioFileWriter {
    let url: URL
    private var file: AVAudioFile?
    private var closed = false
    private let lock = NSLock()
    private(set) var firstHostSeconds: Double?
    private(set) var framesWritten: AVAudioFramePosition = 0
    private(set) var lastError: Error?

    init(url: URL) {
        self.url = url
    }

    /// Va chiamato in modo sincrono: il buffer può non essere più valido dopo il ritorno.
    func write(_ buffer: AVAudioPCMBuffer, hostSeconds: Double?) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, buffer.frameLength > 0 else { return }

        if file == nil {
            let format = buffer.format
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            do {
                file = try AVAudioFile(forWriting: url,
                                       settings: settings,
                                       commonFormat: format.commonFormat,
                                       interleaved: format.isInterleaved)
                firstHostSeconds = hostSeconds
            } catch {
                lastError = error
                closed = true
                return
            }
        }

        do {
            try file?.write(from: buffer)
            framesWritten += AVAudioFramePosition(buffer.frameLength)
        } catch {
            lastError = error
        }
    }

    func writeSilence(seconds: Double, format: AVAudioFormat) {
        var remaining = AVAudioFrameCount(max(0, seconds) * format.sampleRate)
        while remaining > 0 {
            let count = min(remaining, 48_000)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return }
            buffer.frameLength = count
            for audioBuffer in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
                if let data = audioBuffer.mData {
                    memset(data, 0, Int(audioBuffer.mDataByteSize))
                }
            }
            write(buffer, hostSeconds: nil)
            remaining -= count
        }
    }

    /// Rilasciare l'AVAudioFile finalizza il file su disco.
    func close() {
        lock.lock()
        file = nil
        closed = true
        lock.unlock()
    }
}

// MARK: - Microfono (AVCaptureSession: gestisce bene AirPods e dispositivi Bluetooth)

final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private var engine: AVAudioEngine?
    private let writer: AudioFileWriter
    private let deviceUID: String?
    private let enhance: Bool
    private let queue = DispatchQueue(label: "registratore.microphone")
    private static let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                                    channels: 1, interleaved: false)!
    var onError: ((Error) -> Void)?

    /// deviceUID nil = microfono predefinito di sistema.
    /// enhance = elaborazione vocale di sistema (volume automatico, riduzione rumore ed eco),
    /// la stessa delle app di videochiamata. Disponibile solo con il microfono predefinito.
    init(writer: AudioFileWriter, deviceUID: String? = nil, enhance: Bool = false) {
        self.writer = writer
        self.deviceUID = deviceUID
        self.enhance = enhance
    }

    func start() throws {
        if enhance, deviceUID == nil {
            do {
                try startEnhanced()
                return
            } catch {
                // Se l'elaborazione vocale non parte, registriamo comunque il segnale normale.
                engine?.stop()
                engine = nil
            }
        }
        try startSession()
    }

    // MARK: Con elaborazione vocale (AVAudioEngine + voice processing)

    private func startEnhanced() throws {
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        // Non abbassare l'audio delle altre app (la call in cuffia) mentre registriamo.
        input.voiceProcessingOtherAudioDuckingConfiguration =
            AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        engine.mainMixerNode.outputVolume = 0
        try installEnhancedTap()

        NotificationCenter.default.addObserver(self, selector: #selector(engineConfigurationChanged(_:)),
                                               name: .AVAudioEngineConfigurationChange, object: engine)
        engine.prepare()
        try engine.start()
    }

    /// Converte sempre in 48 kHz mono: il file resta coerente anche se il dispositivo cambia formato.
    private func installEnhancedTap() throws {
        guard let input = engine?.inputNode else { return }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noMicrophone }
        // Con l'elaborazione vocale il canale 0 contiene la voce elaborata.
        guard let voiceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                                              channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: voiceFormat, to: Self.outputFormat) else {
            throw RecorderError.noMicrophone
        }
        let writer = self.writer
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
            guard let source = buffer.floatChannelData?[0],
                  let voice = AVAudioPCMBuffer(pcmFormat: voiceFormat, frameCapacity: buffer.frameLength),
                  let dest = voice.floatChannelData?[0] else { return }
            memcpy(dest, source, Int(buffer.frameLength) * MemoryLayout<Float>.size)
            voice.frameLength = buffer.frameLength

            let ratio = Self.outputFormat.sampleRate / voiceFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return voice
            }
            guard error == nil, out.frameLength > 0 else { return }
            let host = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : nil
            writer.write(out, hostSeconds: host)
        }
    }

    /// Le AirPods cambiano profilo Bluetooth quando si apre il microfono: il motore si ferma
    /// e va riavviato con il nuovo formato.
    @objc private func engineConfigurationChanged(_ note: Notification) {
        guard let engine else { return }
        do {
            try installEnhancedTap()
            engine.prepare()
            try engine.start()
        } catch {
            onError?(error)
        }
    }

    // MARK: Segnale diretto (AVCaptureSession)

    private func startSession() throws {
        let device: AVCaptureDevice?
        if let uid = deviceUID {
            device = AVCaptureDevice(uniqueID: uid)
        } else {
            device = AVCaptureDevice.default(for: .audio)
        }
        guard let device else {
            throw deviceUID == nil ? RecorderError.noMicrophone : RecorderError.microphoneUnavailable
        }

        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        // Formato fisso: se il dispositivo cambia modalità (es. AirPods che passano
        // al profilo "chiamata") il sistema converte e il file resta coerente.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true
        ]
        output.setSampleBufferDelegate(self, queue: queue)

        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw RecorderError.microphoneUnavailable
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()

        NotificationCenter.default.addObserver(self, selector: #selector(runtimeError(_:)),
                                               name: .AVCaptureSessionRuntimeError, object: session)
        session.startRunning()
        guard session.isRunning else { throw RecorderError.microphoneUnavailable }
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
        } else {
            session.stopRunning()
        }
    }

    @objc private func runtimeError(_ note: Notification) {
        let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error ?? RecorderError.microphoneUnavailable
        onError?(error)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let writer = self.writer
        SampleBufferAudio.withPCMBuffer(sampleBuffer) { pcm in
            guard let mono = MicrophoneCapture.mono(pcm) else { return }
            writer.write(mono, hostSeconds: pts.isFinite ? pts : nil)
        }
    }

    /// La voce basta in mono: media dei canali in ingresso.
    static func mono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let channels = Int(buffer.format.channelCount)
        if channels == 1 { return buffer }
        guard let source = buffer.floatChannelData,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: buffer.format.sampleRate,
                                         channels: 1,
                                         interleaved: false),
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let dest = out.floatChannelData?[0] else { return nil }
        let frames = Int(buffer.frameLength)
        for i in 0..<frames {
            var sum: Float = 0
            for ch in 0..<channels { sum += source[ch][i] }
            dest[i] = sum / Float(channels)
        }
        out.frameLength = buffer.frameLength
        return out
    }
}

// MARK: - Conversione CMSampleBuffer -> AVAudioPCMBuffer

enum SampleBufferAudio {
    /// Il buffer passato a body è valido solo durante la chiamata.
    static func withPCMBuffer(_ sampleBuffer: CMSampleBuffer, _ body: (AVAudioPCMBuffer) -> Void) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              CMSampleBufferGetNumSamples(sampleBuffer) > 0,
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd) else { return }

        var listSize = 0
        _ = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &listSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil)
        guard listSize > 0 else { return }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: listSize,
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: list,
            bufferListSize: listSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer)
        guard status == noErr,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list, deallocator: nil) else { return }
        withExtendedLifetime(blockBuffer) { body(pcm) }
    }
}

// MARK: - Audio di sistema (call, browser, app) via ScreenCaptureKit

final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let writer: AudioFileWriter
    private let appBundleID: String?
    private let queue = DispatchQueue(label: "registratore.system-audio")
    private var nextPTS: Double?
    var onError: ((Error) -> Void)?

    /// appBundleID nil = tutto l'audio del Mac; altrimenti solo l'audio di quell'app.
    init(writer: AudioFileWriter, appBundleID: String? = nil) {
        self.writer = writer
        self.appBundleID = appBundleID
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw RecorderError.noDisplay }

        let filter: SCContentFilter
        if let bundle = appBundleID {
            // Include anche i processi di supporto (es. com.google.Chrome.helper), che spesso producono l'audio.
            let apps = content.applications.filter {
                $0.bundleIdentifier == bundle || $0.bundleIdentifier.hasPrefix(bundle + ".")
            }
            guard !apps.isEmpty else { throw RecorderError.appNotRunning }
            filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
        } else {
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        }
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // Il video non ci serve: lo teniamo minimo.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio,
              CMSampleBufferDataIsReady(sampleBuffer),
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd) else { return }

        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds

        // Se il sistema non manda buffer durante il silenzio, riempiamo il buco
        // per mantenere la traccia allineata al microfono.
        if let expected = nextPTS, pts.isFinite, pts - expected > 0.05 {
            writer.writeSilence(seconds: min(pts - expected, 3600), format: format)
        }

        let writer = self.writer
        SampleBufferAudio.withPCMBuffer(sampleBuffer) { pcm in
            writer.write(pcm, hostSeconds: pts.isFinite ? pts : nil)
        }
        if pts.isFinite {
            nextPTS = pts + Double(frames) / format.sampleRate
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error)
    }
}

// MARK: - Mix delle due tracce in un unico file

enum AudioMixer {
    static func mix(_ tracks: [Track], to output: URL) async throws {
        // Porta voce e call allo stesso volume prima di unirle (lavoro pesante: fuori dal main thread).
        let leveled: [URL] = await Task.detached(priority: .userInitiated) {
            tracks.map { (try? Leveler.level($0.url)) ?? $0.url }
        }.value

        let composition = AVMutableComposition()
        for (track, url) in zip(tracks, leveled) {
            let asset = AVURLAsset(url: url)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first,
                  let dest = composition.addMutableTrack(withMediaType: .audio,
                                                         preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            let duration = try await asset.load(.duration)
            try dest.insertTimeRange(CMTimeRange(start: .zero, duration: duration),
                                     of: source,
                                     at: CMTime(seconds: track.offset, preferredTimescale: 48_000))
        }

        try? FileManager.default.removeItem(at: output)
        guard let export = AVAssetExportSession(asset: composition,
                                                presetName: AVAssetExportPresetAppleM4A) else {
            throw RecorderError.export
        }
        export.outputURL = output
        export.outputFileType = .m4a
        await export.export()
        if export.status != .completed {
            throw export.error ?? RecorderError.export
        }
    }
}

// MARK: - Livellamento del volume

/// Normalizza una traccia a un volume di riferimento, ignorando i silenzi,
/// con un limitatore morbido che evita la distorsione sui picchi.
enum Leveler {
    static let targetRMS: Float = 0.1     // circa -20 dBFS: volume del parlato
    static let maxGain: Float = 12        // al massimo +21.6 dB, per non amplificare solo rumore
    static let silenceRMS: Float = 0.004  // blocchi più deboli (circa -48 dBFS) = silenzio

    /// Restituisce il file livellato, o l'originale se non serve intervenire.
    static func level(_ url: URL) throws -> URL {
        let input = try AVAudioFile(forReading: url)
        let format = input.processingFormat
        let chunk = AVAudioFrameCount(max(1, format.sampleRate / 10))   // blocchi da 100 ms
        guard format.commonFormat == .pcmFormatFloat32,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return url }

        // 1) Volume medio delle sole parti con suono
        var energy: Double = 0
        var blocks = 0
        while input.framePosition < input.length {
            try input.read(into: buffer, frameCount: chunk)
            guard buffer.frameLength > 0 else { break }
            let rms = blockRMS(buffer)
            if rms > silenceRMS {
                energy += Double(rms * rms)
                blocks += 1
            }
        }
        guard blocks > 0 else { return url }
        let active = Float((energy / Double(blocks)).squareRoot())
        let gain = min(targetRMS / active, maxGain)
        guard abs(gain - 1) > 0.1 else { return url }

        // 2) Applica guadagno e limitatore, scrive un nuovo file
        let out = url.deletingPathExtension().appendingPathExtension("livellato.m4a")
        try? FileManager.default.removeItem(at: out)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let output = try AVAudioFile(forWriting: out, settings: settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        input.framePosition = 0
        while input.framePosition < input.length {
            try input.read(into: buffer, frameCount: chunk)
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
            let frames = Int(buffer.frameLength)
            for ch in 0..<Int(format.channelCount) {
                let samples = data[ch]
                for i in 0..<frames { samples[i] = limit(samples[i] * gain) }
            }
            try output.write(from: buffer)
        }
        return out
    }

    private static func blockRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        var sum: Float = 0
        for ch in 0..<channels {
            let samples = data[ch]
            for i in 0..<frames { sum += samples[i] * samples[i] }
        }
        return (sum / Float(max(1, frames * channels))).squareRoot()
    }

    /// Lineare fino a 0.8, poi compressione morbida che non supera mai 1.0.
    private static func limit(_ x: Float) -> Float {
        let threshold: Float = 0.8
        let magnitude = abs(x)
        guard magnitude > threshold else { return x }
        let compressed = threshold + (1 - threshold) * tanh((magnitude - threshold) / (1 - threshold))
        return x < 0 ? -compressed : compressed
    }
}
