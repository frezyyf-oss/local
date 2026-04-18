import Foundation
import SwiftSignalKit
import Speech

private var sharedRecognizers: [String: NSObject] = [:]

private struct TranscriptionResult {
    var text: String
    var confidence: Float
    var isFinal: Bool
}

private func eahatGramNormalizedSpeechLocale(_ value: String) -> String {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: "-")
    switch normalized.lowercased() {
    case "ru":
        return "ru-RU"
    case "en":
        return "en-US"
    case "de":
        return "de-DE"
    case "fr":
        return "fr-FR"
    case "es":
        return "es-ES"
    case "it":
        return "it-IT"
    case "ja":
        return "ja-JP"
    case "ko":
        return "ko-KR"
    default:
        return normalized
    }
}

private func eahatGramSpeechLocales(appLocale: String) -> [String] {
    var result: [String] = []
    var seen = Set<String>()

    func appendLocale(_ value: String) {
        let normalized = eahatGramNormalizedSpeechLocale(value)
        guard !normalized.isEmpty else {
            return
        }
        if seen.insert(normalized).inserted {
            result.append(normalized)
        }
    }

    appendLocale(appLocale)
    appendLocale(Locale.current.identifier)
    for preferredLanguage in Locale.preferredLanguages {
        appendLocale(preferredLanguage)
    }
    appendLocale("en-US")

    return result
}

private func transcribeAudio(path: String, locale: String) -> Signal<TranscriptionResult?, NoError> {
    return Signal { subscriber in
        let disposable = MetaDisposable()
        
        if #available(iOS 13.0, *) {
            SFSpeechRecognizer.requestAuthorization { status in
                Queue.mainQueue().async {
                    switch status {
                    case .notDetermined:
                        subscriber.putNext(nil)
                        subscriber.putCompletion()
                    case .restricted:
                        subscriber.putNext(nil)
                        subscriber.putCompletion()
                    case .denied:
                        subscriber.putNext(nil)
                        subscriber.putCompletion()
                    case .authorized:
                        let speechRecognizer: SFSpeechRecognizer
                        if let sharedRecognizer = sharedRecognizers[locale] as? SFSpeechRecognizer {
                            speechRecognizer = sharedRecognizer
                        } else {
                            guard let speechRecognizerValue = SFSpeechRecognizer(locale: Locale(identifier: locale)), speechRecognizerValue.isAvailable else {
                                subscriber.putNext(nil)
                                subscriber.putCompletion()
                                
                                return
                            }
                            speechRecognizerValue.defaultTaskHint = .dictation
                            sharedRecognizers[locale] = speechRecognizerValue
                            speechRecognizer = speechRecognizerValue
                        }
                        
                        let tempFilePath = NSTemporaryDirectory() + "/\(UInt64.random(in: 0 ... UInt64.max)).m4a"
                        let _ = try? FileManager.default.copyItem(atPath: path, toPath: tempFilePath)
                        
                        let request = SFSpeechURLRecognitionRequest(url: URL(fileURLWithPath: tempFilePath))
                        if #available(iOS 16.0, *) {
                            request.addsPunctuation = true
                        }
                        request.requiresOnDeviceRecognition = false
                        request.shouldReportPartialResults = false
                        
                        let task = speechRecognizer.recognitionTask(with: request, resultHandler: { result, error in
                            if let result = result {
                                var confidence: Float = 0.0
                                for segment in result.bestTranscription.segments {
                                    confidence += segment.confidence
                                }
                                confidence /= Float(result.bestTranscription.segments.count)
                                subscriber.putNext(TranscriptionResult(text: result.bestTranscription.formattedString, confidence: confidence, isFinal: result.isFinal))
                                
                                if result.isFinal {
                                    subscriber.putCompletion()
                                }
                            } else {
                                print("transcribeAudio: locale: \(locale), error: \(String(describing: error))")
                                
                                subscriber.putNext(nil)
                                subscriber.putCompletion()
                            }
                        })
                        
                        disposable.set(ActionDisposable {
                            task.cancel()
                        })
                    @unknown default:
                        subscriber.putNext(nil)
                        subscriber.putCompletion()
                    }
                }
            }
        } else {
            subscriber.putNext(nil)
            subscriber.putCompletion()
        }
        
        return disposable
    }
    |> runOn(.mainQueue())
}

public struct LocallyTranscribedAudio {
    public var text: String
    public var isFinal: Bool
}

public func transcribeAudio(path: String, appLocale: String) -> Signal<LocallyTranscribedAudio?, NoError> {
    var signals: [Signal<TranscriptionResult?, NoError>] = []
    let locales = eahatGramSpeechLocales(appLocale: appLocale)
    for locale in locales {
        signals.append(transcribeAudio(path: path, locale: locale))
    }
    var resultSignal: Signal<[TranscriptionResult?], NoError> = .single([])
    for signal in signals {
        resultSignal = resultSignal |> mapToSignal { result -> Signal<[TranscriptionResult?], NoError> in
            return signal |> map { next in
                return result + [next]
            }
        }
    }
    
    return resultSignal
    |> map { results -> LocallyTranscribedAudio? in
        let sortedResults = results.compactMap({ $0 }).sorted(by: { lhs, rhs in
            return lhs.confidence > rhs.confidence
        })
        return sortedResults.first.flatMap { result -> LocallyTranscribedAudio in
            return LocallyTranscribedAudio(text: result.text, isFinal: result.isFinal)
        }
    }
}
