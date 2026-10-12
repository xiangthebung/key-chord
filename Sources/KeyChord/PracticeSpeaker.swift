import AVFoundation

/// Injectable speech keeps native regression checks silent and independent of installed voices.
protocol PracticeSpeaking: AnyObject {
    var isAvailable: Bool { get }
    @discardableResult func speak(_ text: String) -> Bool
    func stop()
}

/// macOS speech synthesis provides prompts and feedback without microphone access.
final class PracticeSpeaker: PracticeSpeaking {
    private let synthesizer = AVSpeechSynthesizer()
    private var voice: AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice(language: "en-US")
            ?? AVSpeechSynthesisVoice.speechVoices().first { $0.language.hasPrefix("en-") }
    }
    var isAvailable: Bool { voice != nil }

    @discardableResult
    func speak(_ text: String) -> Bool {
        stop()
        guard let voice else { return false }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        synthesizer.speak(utterance)
        return true
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
