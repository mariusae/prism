#if os(iOS)
import AVFoundation
import Speech
import SwiftUI
import UIKit

/// Words spoken, written down by Apple's own speech recognition — on the
/// device when it can be. What was said so far told as it comes, and all
/// of it when let go.
@MainActor
final class Listening {
    enum Failure: Error { case notAllowed, unavailable }

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// What has been heard so far.
    private(set) var text = ""
    /// What was said before the utterance being heard now: the recogniser,
    /// after a pause, starts each utterance afresh — what it reports is
    /// then that alone.
    private var before = ""
    /// The utterance being heard now, as last reported.
    private var utterance = ""
    /// An utterance just ended: the next report may start another.
    private var utteranceEnded = false
    private var finished: CheckedContinuation<Void, Never>?
    private var isFinal = false

    /// Asks, once, to hear and to recognise speech: both are needed.
    static func allowed() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            _ = await withCheckedContinuation { (done: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0) }
            }
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    /// Listening, from now: `heard` told what has been said so far.
    func start(heard: @escaping @MainActor (String) -> Void) throws {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { throw Failure.notAllowed }
        guard let recognizer = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer(), recognizer.isAvailable else { throw Failure.unavailable }
        text = ""
        before = ""
        utterance = ""
        utteranceEnded = false
        isFinal = false
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // No microphone to hear with — a simulator without one: said, not crashed on.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw Failure.unavailable
        }
        input.removeTap(onBus: 0)
        Self.tap(input, format: format, into: request)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
        self.request = request
        task = Self.recognise(request, with: recognizer) { [weak self] said, ended, final in
            guard let self else { return }
            if let said {
                self.take(said, ended: ended)
                heard(self.text)
            }
            if final { self.end() }
        }
    }

    // What the microphone hears and what the recogniser says come on
    // threads of their own: neither closure is the main actor's.
    private nonisolated static func tap(_ input: AVAudioInputNode, format: AVAudioFormat, into request: SFSpeechAudioBufferRecognitionRequest) {
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
    }

    private nonisolated static func recognise(_ request: SFSpeechAudioBufferRecognitionRequest, with recognizer: SFSpeechRecognizer,
                                              told: @escaping @MainActor (String?, Bool, Bool) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            let said = result?.bestTranscription.formattedString
            // Told how it was said: the utterance is over.
            let ended = result?.speechRecognitionMetadata != nil
            let final = result?.isFinal == true || error != nil
            DispatchQueue.main.async { MainActor.assumeIsolated { told(said, ended, final) } }
        }
    }

    /// Let go: what was said, once the last of it is recognised — waited
    /// for a moment at most.
    func stop() async -> String {
        guard request != nil else { return text }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        if !isFinal {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                finished = done
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.end() }
            }
        }
        task?.cancel()
        task = nil
        request = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Given up on: the microphone let go, nothing waited for.
    func cancel() {
        guard request != nil else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        task?.cancel()
        task = nil
        request = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// What the recogniser reports, added to what came before it: a report
    /// that starts over — after an utterance ended, or one much shorter
    /// that doesn't begin as the last did — is a new utterance, the last kept.
    private func take(_ said: String, ended: Bool) {
        let continues = Self.opening(said) == Self.opening(utterance) || utterance.isEmpty
        if !continues, utteranceEnded || said.count < utterance.count / 2 { before = Self.join(before, utterance) }
        utterance = said
        utteranceEnded = ended
        text = Self.join(before, utterance)
    }

    /// The first words, to tell whether a report goes on from the last.
    private static func opening(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }.prefix(12))
    }

    private static func join(_ a: String, _ b: String) -> String {
        let a = a.trimmingCharacters(in: .whitespaces), b = b.trimmingCharacters(in: .whitespaces)
        return a.isEmpty ? b : b.isEmpty ? a : a + " " + b
    }

    private func end() {
        isFinal = true
        finished?.resume()
        finished = nil
    }
}

/// + held: what is said, heard, and shown over the bar as it comes. Let
/// go, a new note of it at the top of the river — or, slid well up from
/// the + first, or nothing said, nothing.
@MainActor
@Observable
final class HeldDictation {
    /// + held, as a microphone.
    private(set) var listening = false
    /// What has been heard so far.
    private(set) var heard = ""
    /// Why it can't listen, said for a moment.
    private(set) var problem: String?
    @ObservationIgnored private var dictation: Listening?
    @ObservationIgnored private var asking = false

    func begin() {
        guard dictation == nil, !asking else { return }
        listening = true
        problem = nil
        heard = ""
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        asking = true
        Task { @MainActor in
            let allowed = await Listening.allowed()
            asking = false
            guard allowed else {
                listening = false
                return say("Weft can\u{2019}t listen: allow the microphone and speech recognition in Settings.")
            }
            // Let go while being asked: nothing.
            guard listening else { return }
            let dictation = Listening()
            do {
                try dictation.start { [weak self, weak dictation] text in
                    guard let self, let dictation, self.dictation === dictation else { return }
                    self.heard = text
                }
                self.dictation = dictation
            } catch {
                listening = false
                say("Dictation isn\u{2019}t available right now.")
            }
        }
    }

    /// Let go: kept, or — `cancelled`, slid away first — given up.
    func end(cancelled: Bool, store: GraphStore) {
        listening = false
        guard let dictation else { return }
        self.dictation = nil
        Task { @MainActor in
            if cancelled {
                dictation.cancel()
                heard = ""
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                return
            }
            let text = await dictation.stop()
            heard = ""
            // Nothing said: no note.
            guard !text.isEmpty else { return }
            withAnimation(.snappy(duration: 0.28)) { _ = store.newNote(saying: text) }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    private func say(_ words: String) {
        problem = words
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if problem == words { problem = nil }
        }
    }
}

/// A finger on a view, as UIKit sees it: down the moment it lands, up with
/// how far it went, or taken away.
struct Press: UIGestureRecognizerRepresentable {
    enum Phase { case down, up(CGSize), taken }
    let phase: (Phase) -> Void

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let press = UILongPressGestureRecognizer()
        press.minimumPressDuration = 0
        press.allowableMovement = .greatestFiniteMagnitude
        return press
    }

    func handleUIGestureRecognizerAction(_ press: UILongPressGestureRecognizer, context: Context) {
        let at = press.location(in: press.view)
        switch press.state {
        case .began:
            context.coordinator.start = at
            phase(.down)
        case .ended:
            let start = context.coordinator.start
            phase(.up(CGSize(width: at.x - start.x, height: at.y - start.y)))
        case .cancelled, .failed:
            phase(.taken)
        default:
            break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    final class Coordinator { var start = CGPoint.zero }
}

/// Over the bar while + is held: what is heard, as it comes — or, for a
/// moment, why it can't listen.
struct HeardBubble: View {
    let text: String
    /// Still waiting for words: said quietly.
    var quiet = false

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(quiet ? Color.inkSecondary : Color.inkText)
            .lineLimit(4)
            // The last of what was heard stays in sight.
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
            .allowsHitTesting(false)
    }
}
#endif
