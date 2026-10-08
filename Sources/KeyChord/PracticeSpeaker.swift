import AVFoundation

/// Keeps one spoken prompt alive and cancels it when the learner leaves or requests another word.
final class PracticeSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    var onSpeakingChanged: ((Bool) -> Void)?
    private let synthesizer = AVSpeechSynthesizer()
    private var current: AVSpeechUtterance?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    @discardableResult
    func speak(_ word: String) -> Bool {
        stop()
        guard let voice = AVSpeechSynthesisVoice(language: "en-US")
            ?? AVSpeechSynthesisVoice.speechVoices().first(where: { $0.language.hasPrefix("en-") }) else { return false }
        let utterance = AVSpeechUtterance(string: word)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        current = utterance
        synthesizer.speak(utterance)
        return true
    }

    func stop() {
        current = nil
        synthesizer.stopSpeaking(at: .immediate)
        onSpeakingChanged?(false)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        guard utterance === current else { return }
        onSpeakingChanged?(true)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard utterance === current else { return }
        current = nil
        onSpeakingChanged?(false)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        guard utterance === current else { return }
        current = nil
        onSpeakingChanged?(false)
    }
}
