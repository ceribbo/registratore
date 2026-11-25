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

// MARK: - Microfono

final class MicrophoneCapture {
    private let engine = AVAudioEngine()
    private let writer: AudioFileWriter
    private let deviceID: AudioDeviceID?

    /// deviceID nil = microfono predefinito di sistema.
    init(writer: AudioFileWriter, deviceID: AudioDeviceID? = nil) {
        self.writer = writer
        self.deviceID = deviceID
    }

    func start() throws {
        let input = engine.inputNode
        if var id = deviceID {
            guard let unit = input.audioUnit,
                  AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                       kAudioUnitScope_Global, 0, &id,
                                       UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
            else { throw RecorderError.microphoneUnavailable }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecorderError.noMicrophone
        }
        let writer = self.writer
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
            guard let mono = MicrophoneCapture.mono(buffer) else { return }
            let host = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : nil
            writer.write(mono, hostSeconds: host)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
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

        writer.write(pcm, hostSeconds: pts.isFinite ? pts : nil)
        if pts.isFinite {
            nextPTS = pts + Double(frames) / format.sampleRate
        }
        _ = blockBuffer
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error)
    }
}

// MARK: - Mix delle due tracce in un unico file

enum AudioMixer {
    static func mix(_ tracks: [Track], to output: URL) async throws {
        let composition = AVMutableComposition()
        for track in tracks {
            let asset = AVURLAsset(url: track.url)
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
