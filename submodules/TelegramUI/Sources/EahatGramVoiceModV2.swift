import Foundation
import AVFoundation
import SwiftSignalKit
import TelegramCore
import AccountContext
import ConvertOpusToAAC
import LocalAudioTranscription
import FFMpegBinding
import OpusBinding
import AudioWaveform
import PeerInfoScreen

private let eahatGramVoiceModEnabledDefaultsKey = "eahatGram.voiceModEnabled"
private let eahatGramVoiceModV2EnabledDefaultsKey = "eahatGram.voiceModV2Enabled"
private let eahatGramVoiceModV2VoiceDefaultsKey = "eahatGram.voiceModV2Voice"
private let eahatGramVoiceMessageFrameByteCount = 960 * MemoryLayout<Int16>.size

func eahatGramVoiceModV2IsActive() -> Bool {
    let voiceModEnabled = UserDefaults.standard.object(forKey: eahatGramVoiceModEnabledDefaultsKey) as? Bool ?? false
    let voiceModV2Enabled = UserDefaults.standard.object(forKey: eahatGramVoiceModV2EnabledDefaultsKey) as? Bool ?? false
    return voiceModEnabled && voiceModV2Enabled
}

private func eahatGramCurrentVoiceModV2Voice() -> EahatGramVoiceModV2Voice {
    return EahatGramVoiceModV2Voice(
        rawValue: UserDefaults.standard.string(forKey: eahatGramVoiceModV2VoiceDefaultsKey) ?? EahatGramVoiceModV2Voice.ruNeutral.rawValue
    ) ?? .ruNeutral
}

private struct EahatGramVoiceModV2Configuration {
    let languageCode: String
    let rate: Float
    let pitchMultiplier: Float
    let volume: Float
}

private extension EahatGramVoiceModV2Voice {
    var configuration: EahatGramVoiceModV2Configuration {
        switch self {
        case .ruNeutral:
            return EahatGramVoiceModV2Configuration(languageCode: "ru-RU", rate: 0.47, pitchMultiplier: 1.0, volume: 1.0)
        case .ruSoft:
            return EahatGramVoiceModV2Configuration(languageCode: "ru-RU", rate: 0.43, pitchMultiplier: 0.93, volume: 1.0)
        case .ruFast:
            return EahatGramVoiceModV2Configuration(languageCode: "ru-RU", rate: 0.56, pitchMultiplier: 1.01, volume: 1.0)
        case .ruLow:
            return EahatGramVoiceModV2Configuration(languageCode: "ru-RU", rate: 0.46, pitchMultiplier: 0.86, volume: 1.0)
        case .enNeutral:
            return EahatGramVoiceModV2Configuration(languageCode: "en-US", rate: 0.47, pitchMultiplier: 1.0, volume: 1.0)
        case .enSoft:
            return EahatGramVoiceModV2Configuration(languageCode: "en-US", rate: 0.43, pitchMultiplier: 0.94, volume: 1.0)
        case .enFast:
            return EahatGramVoiceModV2Configuration(languageCode: "en-US", rate: 0.57, pitchMultiplier: 1.02, volume: 1.0)
        case .enLow:
            return EahatGramVoiceModV2Configuration(languageCode: "en-US", rate: 0.46, pitchMultiplier: 0.87, volume: 1.0)
        case .deNeutral:
            return EahatGramVoiceModV2Configuration(languageCode: "de-DE", rate: 0.48, pitchMultiplier: 1.0, volume: 1.0)
        case .frNeutral:
            return EahatGramVoiceModV2Configuration(languageCode: "fr-FR", rate: 0.48, pitchMultiplier: 1.02, volume: 1.0)
        case .esNeutral:
            return EahatGramVoiceModV2Configuration(languageCode: "es-ES", rate: 0.49, pitchMultiplier: 1.0, volume: 1.0)
        case .itNeutral:
            return EahatGramVoiceModV2Configuration(languageCode: "it-IT", rate: 0.49, pitchMultiplier: 1.03, volume: 1.0)
        case .jaNeutral:
            return EahatGramVoiceModV2Configuration(languageCode: "ja-JP", rate: 0.5, pitchMultiplier: 1.0, volume: 1.0)
        case .koNeutral:
            return EahatGramVoiceModV2Configuration(languageCode: "ko-KR", rate: 0.5, pitchMultiplier: 1.0, volume: 1.0)
        }
    }
}

private func eahatGramResolvedSpeechVoice(_ preset: EahatGramVoiceModV2Voice) -> AVSpeechSynthesisVoice? {
    let configuration = preset.configuration
    if let voice = AVSpeechSynthesisVoice(language: configuration.languageCode) {
        return voice
    }
    let languagePrefix = configuration.languageCode.components(separatedBy: "-").first ?? configuration.languageCode
    return AVSpeechSynthesisVoice.speechVoices().first(where: { $0.language.hasPrefix(languagePrefix) })
}

private func eahatGramClampSample(_ value: Int32) -> Int16 {
    return Int16(clamping: max(Int32(Int16.min), min(Int32(Int16.max), value)))
}

private final class EahatGramWaveformBuilder {
    private var compressedWaveformSamples = Data()
    private var currentPeak: Int64 = 0
    private var currentPeakCount: Int = 0
    private var peakCompressionFactor: Int = 1

    func append(samples: UnsafePointer<Int16>, count: Int) {
        guard count > 0 else {
            return
        }
        for index in 0 ..< count {
            var sample = samples.advanced(by: index).pointee
            if sample < 0 {
                if sample == Int16.min {
                    sample = Int16.max
                } else {
                    sample = -sample
                }
            }

            self.currentPeak = max(Int64(sample), self.currentPeak)
            self.currentPeakCount += 1
            if self.currentPeakCount == self.peakCompressionFactor {
                var compressedPeak = self.currentPeak
                withUnsafeBytes(of: &compressedPeak) { rawBuffer in
                    self.compressedWaveformSamples.append(rawBuffer.bindMemory(to: UInt8.self))
                }
                self.currentPeak = 0
                self.currentPeakCount = 0

                let compressedSampleCount = self.compressedWaveformSamples.count / 2
                if compressedSampleCount == 200 {
                    self.compressedWaveformSamples.withUnsafeMutableBytes { rawCompressedSamples in
                        guard let baseAddress = rawCompressedSamples.baseAddress else {
                            return
                        }
                        let compressedSamples = baseAddress.assumingMemoryBound(to: Int16.self)
                        for compressedIndex in 0 ..< 100 {
                            let maxSample = Int64(max(compressedSamples[compressedIndex * 2], compressedSamples[compressedIndex * 2 + 1]))
                            compressedSamples[compressedIndex] = Int16(maxSample)
                        }
                    }
                    self.compressedWaveformSamples.count = 100 * 2
                    self.peakCompressionFactor *= 2
                }
            }
        }
    }

    func makeBitstream() -> Data? {
        guard !self.compressedWaveformSamples.isEmpty else {
            return nil
        }

        let scaledSamplesMemory = malloc(100 * 2)!
        defer {
            free(scaledSamplesMemory)
        }
        memset(scaledSamplesMemory, 0, 100 * 2)

        let scaledSamples = scaledSamplesMemory.assumingMemoryBound(to: Int16.self)
        let count = self.compressedWaveformSamples.count / 2
        self.compressedWaveformSamples.withUnsafeMutableBytes { rawSamples in
            guard let baseAddress = rawSamples.baseAddress else {
                return
            }
            let samples = baseAddress.assumingMemoryBound(to: Int16.self)
            for index in 0 ..< count {
                let sample = samples[index]
                let scaledIndex = index * 100 / count
                if scaledSamples[scaledIndex] < sample {
                    scaledSamples[scaledIndex] = sample
                }
            }

            var sumSamples: Int64 = 0
            for index in 0 ..< 100 {
                sumSamples += Int64(scaledSamples[index])
            }
            var calculatedPeak = UInt16((Double(sumSamples) * 1.8 / 100.0))
            if calculatedPeak < 2500 {
                calculatedPeak = 2500
            }

            for index in 0 ..< 100 {
                let sample = UInt16(Int64(scaledSamples[index]))
                let minPeak = min(Int64(sample), Int64(calculatedPeak))
                let resultPeak = minPeak * 31 / Int64(calculatedPeak)
                scaledSamples[index] = Int16(clamping: min(31, resultPeak))
            }
        }

        let waveform = AudioWaveform(samples: Data(bytes: scaledSamplesMemory, count: 100 * 2), peak: 31)
        let bitstream = waveform.makeBitstream()
        return AudioWaveform(bitstream: bitstream, bitsPerSample: 5).makeBitstream()
    }
}

private final class EahatGramSpeechSynthesisOperation: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let queue: Queue
    private let text: String
    private let preset: EahatGramVoiceModV2Voice
    private let completion: (RecordedAudioData?) -> Void
    private let synthesizer: AVSpeechSynthesizer
    private let dataItem: TGDataItem
    private let writer: TGOggOpusWriter
    private let waveformBuilder = EahatGramWaveformBuilder()
    private let targetFormat: AVAudioFormat
    private var bufferedPcm = Data()
    private var finished = false
    private var hasSamples = false

    init(queue: Queue, text: String, preset: EahatGramVoiceModV2Voice, completion: @escaping (RecordedAudioData?) -> Void) {
        self.queue = queue
        self.text = text
        self.preset = preset
        self.completion = completion
        self.synthesizer = AVSpeechSynthesizer()
        self.dataItem = TGDataItem()
        self.writer = TGOggOpusWriter()
        self.targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 1, interleaved: false)!

        super.init()

        self.synthesizer.delegate = self
    }

    func start() {
        guard self.writer.begin(with: self.dataItem) else {
            self.finish(result: nil)
            return
        }

        let configuration = self.preset.configuration
        let utterance = AVSpeechUtterance(string: self.text)
        utterance.voice = eahatGramResolvedSpeechVoice(self.preset)
        utterance.rate = configuration.rate
        utterance.pitchMultiplier = configuration.pitchMultiplier
        utterance.volume = configuration.volume

        if #available(iOS 13.0, *) {
            self.synthesizer.write(utterance) { [weak self] buffer in
                guard let self else {
                    return
                }
                self.queue.async {
                    self.process(buffer: buffer)
                }
            }
        } else {
            self.finish(result: nil)
        }
    }

    func cancel() {
        self.queue.async {
            if self.finished {
                return
            }
            self.finished = true
            self.synthesizer.stopSpeaking(at: .immediate)
            self.completion(nil)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        self.queue.async {
            self.finalizeEncoding()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        self.queue.async {
            self.finish(result: nil)
        }
    }

    private func process(buffer: AVAudioBuffer) {
        guard !self.finished else {
            return
        }
        guard let pcmBuffer = buffer as? AVAudioPCMBuffer else {
            return
        }
        guard pcmBuffer.frameLength > 0 else {
            return
        }
        guard let convertedBuffer = self.convert(buffer: pcmBuffer) else {
            return
        }
        guard let channelData = convertedBuffer.int16ChannelData else {
            return
        }

        let frameLength = Int(convertedBuffer.frameLength)
        guard frameLength > 0 else {
            return
        }

        self.hasSamples = true
        let samples = channelData[0]
        self.waveformBuilder.append(samples: UnsafePointer(samples), count: frameLength)
        let byteCount = frameLength * MemoryLayout<Int16>.size
        self.bufferedPcm.append(UnsafeRawPointer(samples).assumingMemoryBound(to: UInt8.self), count: byteCount)

        while self.bufferedPcm.count >= eahatGramVoiceMessageFrameByteCount {
            var frameData = Data(self.bufferedPcm.prefix(eahatGramVoiceMessageFrameByteCount))
            let wroteFrame = frameData.withUnsafeMutableBytes { (rawBuffer: UnsafeMutableRawBufferPointer) -> Bool in
                guard let baseAddress = rawBuffer.baseAddress else {
                    return false
                }
                return self.writer.writeFrame(baseAddress.assumingMemoryBound(to: UInt8.self), frameByteCount: UInt(eahatGramVoiceMessageFrameByteCount))
            }
            guard wroteFrame else {
                self.finish(result: nil)
                return
            }
            self.bufferedPcm.removeFirst(eahatGramVoiceMessageFrameByteCount)
        }
    }

    private func convert(buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format.commonFormat == self.targetFormat.commonFormat && buffer.format.sampleRate == self.targetFormat.sampleRate && buffer.format.channelCount == self.targetFormat.channelCount && buffer.format.isInterleaved == self.targetFormat.isInterleaved {
            return buffer
        }

        guard let converter = AVAudioConverter(from: buffer.format, to: self.targetFormat) else {
            return nil
        }
        let sampleRateRatio = self.targetFormat.sampleRate / buffer.format.sampleRate
        let frameCapacity = AVAudioFrameCount(max(1.0, ceil(Double(buffer.frameLength) * sampleRateRatio)))
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: self.targetFormat, frameCapacity: frameCapacity) else {
            return nil
        }

        var pendingBuffer: AVAudioPCMBuffer? = buffer
        var conversionError: NSError?
        let status = converter.convert(to: convertedBuffer, error: &conversionError) { _, outStatus in
            if let currentBuffer = pendingBuffer {
                outStatus.pointee = .haveData
                pendingBuffer = nil
                return currentBuffer
            } else {
                outStatus.pointee = .endOfStream
                return nil
            }
        }
        if conversionError != nil {
            return nil
        }
        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            return convertedBuffer
        case .error:
            return nil
        @unknown default:
            return nil
        }
    }

    private func finalizeEncoding() {
        guard !self.finished else {
            return
        }

        if !self.bufferedPcm.isEmpty {
            let remainingCount = self.bufferedPcm.count
            let wroteFrame = self.bufferedPcm.withUnsafeMutableBytes { (rawBuffer: UnsafeMutableRawBufferPointer) -> Bool in
                guard let baseAddress = rawBuffer.baseAddress else {
                    return false
                }
                return self.writer.writeFrame(baseAddress.assumingMemoryBound(to: UInt8.self), frameByteCount: UInt(remainingCount))
            }
            if !wroteFrame {
                self.finish(result: nil)
                return
            }
            self.bufferedPcm.removeAll(keepingCapacity: false)
        }

        guard self.writer.writeFrame(nil, frameByteCount: 0), self.hasSamples else {
            self.finish(result: nil)
            return
        }

        let result = RecordedAudioData(
            compressedData: self.dataItem.data(),
            resumeData: nil,
            duration: self.writer.encodedDuration(),
            waveform: self.waveformBuilder.makeBitstream(),
            trimRange: nil
        )
        self.finish(result: result)
    }

    private func finish(result: RecordedAudioData?) {
        guard !self.finished else {
            return
        }
        self.finished = true
        self.completion(result)
    }
}

private func eahatGramSynthesizeVoiceMessage(text: String, preset: EahatGramVoiceModV2Voice) -> Signal<RecordedAudioData?, NoError> {
    return Signal { subscriber in
        let operation = EahatGramSpeechSynthesisOperation(queue: Queue(), text: text, preset: preset, completion: { result in
            subscriber.putNext(result)
            subscriber.putCompletion()
        })
        Queue.mainQueue().async {
            operation.start()
        }
        return ActionDisposable {
            Queue.mainQueue().async {
                operation.cancel()
            }
        }
    }
}

func eahatGramTransformVoiceMessageForModeV2(sourcePath: String, trimRange: Range<Double>?, appLocale: String) -> Signal<RecordedAudioData?, NoError> {
    return Signal { subscriber in
        let disposable = MetaDisposable()
        let trimmedFile: EngineTempBox.File?
        let effectiveSourcePath: String
        if let trimRange {
            let tempFile = EngineTempBox.shared.tempFile(fileName: "audio.ogg")
            FFMpegOpusTrimmer.trim(sourcePath, to: tempFile.path, start: trimRange.lowerBound, end: trimRange.upperBound)
            trimmedFile = tempFile
            effectiveSourcePath = tempFile.path
        } else {
            trimmedFile = nil
            effectiveSourcePath = sourcePath
        }
        let convertedFile = EngineTempBox.shared.tempFile(fileName: "audio.m4a")

        let signal =
            convertOpusToAAC(sourcePath: effectiveSourcePath, allocateTempFile: {
                convertedFile.path
            })
            |> mapToSignal { result -> Signal<LocallyTranscribedAudio?, NoError> in
                guard let result else {
                    return .single(nil)
                }
                let preset = eahatGramCurrentVoiceModV2Voice()
                return transcribeAudio(path: result, appLocale: appLocale, preferredLocales: [preset.configuration.languageCode])
            }
            |> mapToSignal { result -> Signal<RecordedAudioData?, NoError> in
                guard let result else {
                    return .single(nil)
                }
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    return .single(nil)
                }
                return eahatGramSynthesizeVoiceMessage(text: text, preset: eahatGramCurrentVoiceModV2Voice())
            }

        disposable.set(signal.start(next: { result in
            subscriber.putNext(result)
        }, completed: {
            subscriber.putCompletion()
        }))

        return ActionDisposable {
            disposable.dispose()
            if let trimmedFile {
                EngineTempBox.shared.dispose(trimmedFile)
            }
            EngineTempBox.shared.dispose(convertedFile)
        }
    }
}

func eahatGramTransformVoiceMessageForModeV2(data: Data, trimRange: Range<Double>?, appLocale: String) -> Signal<RecordedAudioData?, NoError> {
    return Signal { subscriber in
        let sourceFile = EngineTempBox.shared.tempFile(fileName: "audio.ogg")
        do {
            try data.write(to: URL(fileURLWithPath: sourceFile.path), options: .atomic)
        } catch {
            EngineTempBox.shared.dispose(sourceFile)
            subscriber.putNext(nil)
            subscriber.putCompletion()
            return EmptyDisposable
        }

        let disposable = MetaDisposable()
        disposable.set((eahatGramTransformVoiceMessageForModeV2(sourcePath: sourceFile.path, trimRange: trimRange, appLocale: appLocale)
        |> deliverOnMainQueue).start(next: { result in
            subscriber.putNext(result)
        }, completed: {
            subscriber.putCompletion()
        }))

        return ActionDisposable {
            disposable.dispose()
            EngineTempBox.shared.dispose(sourceFile)
        }
    }
}
