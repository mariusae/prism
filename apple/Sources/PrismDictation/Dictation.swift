import AVFoundation
import Speech

/// Words spoken, written down: by ElevenLabs' Scribe while online — a
/// token for it to be had — else by Apple's own recognition, on the
/// device. What was said so far told as it comes, and all of it when let
/// go. The phone's and the Mac's.
@MainActor
public final class Dictation {
    /// A single-use token for Scribe, or nil when there is none to be had —
    /// signed out, no relay.
    public static var scribeToken: (@Sendable () async throws -> String)?

    /// What happened, said for whoever keeps a log: the app's to set.
    public static var log: (@MainActor (String) -> Void)?
    static func note(_ words: String) { log?(words) }

    /// Who is writing it down: ElevenLabs, once its session has started —
    /// asked for, till then — or Apple's recognition, on the device.
    public enum Engine: Equatable, Sendable {
        case connecting, scribe, apple

        /// Its mark, an SF Symbol: a waveform for ElevenLabs — faint while
        /// it connects — Apple's for Apple's.
        public var symbol: String { self == .apple ? "apple.logo" : "waveform" }

        public var name: String {
            switch self {
            case .connecting: "Connecting to ElevenLabs"
            case .scribe: "ElevenLabs"
            case .apple: "Apple, on this device"
            }
        }
    }

    /// The engine now, told as it changes.
    public private(set) var engine: Engine? {
        didSet {
            guard engine != oldValue, let engine else { return }
            if engine != .connecting { Self.note("Dictating with \(engine.name)") }
            onEngine?(engine)
        }
    }
    public var onEngine: (@MainActor (Engine) -> Void)?

    private var scribe: ScribeDictation?
    private var apple: AppleDictation?
    private var stopped = false

    public init() {}

    /// Asks, once, to hear and to recognise speech: hearing is needed;
    /// recognising only for Apple's way, offline.
    public static func allowed() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            _ = await withCheckedContinuation { done in
                SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0) }
            }
        }
        return await AVAudioApplication.requestRecordPermission()
    }

    /// A token got ahead of time, so that the words go to Scribe at once:
    /// good for 15 minutes; taken by the next dictation.
    private static var spare: (token: String, got: Date)?
    private static var fetching = false

    /// A token ready for the next dictation, if there can be one.
    public static func prepare() {
        guard let scribeToken, !fetching, spare.map({ Date().timeIntervalSince($0.got) > 12 * 60 }) ?? true else { return }
        fetching = true
        Task { @MainActor in
            defer { fetching = false }
            do {
                spare = (try await scribeToken(), Date())
            } catch {
                Dictation.note("No token for ElevenLabs" + ": " + error.localizedDescription)
            }
        }
    }

    /// The spare token, else one asked for now — a moment at most.
    private static func token() async -> String? {
        if let spare, Date().timeIntervalSince(spare.got) < 13 * 60 {
            Self.spare = nil
            return spare.token
        }
        guard let scribeToken else { return nil }
        // Offline, not long: Apple's way instead.
        return await withTaskGroup(of: String?.self) { group in
            group.addTask { try? await scribeToken() }
            group.addTask {
                try? await Task.sleep(for: .seconds(1.5))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// As many as ElevenLabs takes, each as long as it takes — a longer one
    /// and it refuses the whole session — the first of each, case aside.
    nonisolated static let termLimit = 50
    nonisolated static let termLength = 20

    /// The words dictation should favour, of some names — of notes pinned,
    /// or lately written in: people, projects — the short ones, each once.
    public nonisolated static func terms(from titles: [String]) -> [String] {
        var seen = Set<String>(), terms: [String] = []
        for title in titles {
            let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.count <= termLength, seen.insert(title.lowercased()).inserted else { continue }
            terms.append(title)
            if terms.count == termLimit { break }
        }
        return terms
    }

    /// Listening, from now: `heard` told what has been said so far;
    /// `keyterms` — names, titles — the words to favour.
    public func start(keyterms: [String] = [], heard: @escaping @MainActor (String) -> Void) throws {
        if Self.scribeToken != nil {
            // Heard at once; written down by Scribe once there is a token.
            let scribe = ScribeDictation()
            scribe.onStarted = { [weak self] in self?.engine = .scribe }
            do {
                try scribe.start(token: { await Self.token() }, keyterms: keyterms, heard: heard) { [weak self] _ in
                    // No token, or not answered: Apple's way, from here.
                    guard let self, !self.stopped else { return }
                    self.scribe = nil
                    try? self.startApple(heard: heard)
                }
                self.scribe = scribe
                engine = .connecting
                return
            } catch {
                scribe.cancel()
                Dictation.note("ElevenLabs could not start" + ": " + error.localizedDescription)
            }
        }
        try startApple(heard: heard)
    }

    private func startApple(heard: @escaping @MainActor (String) -> Void) throws {
        let apple = AppleDictation()
        try apple.start(heard: heard)
        self.apple = apple
        engine = .apple
    }

    /// Let go: what was said, once the last of it is written down.
    public func stop() async -> String {
        stopped = true
        defer { Self.prepare() }
        if let scribe { return await scribe.stop() }
        if let apple { return await apple.stop() }
        return ""
    }

    /// Given up on: nothing to be written down.
    public func cancel() {
        stopped = true
        defer { Self.prepare() }
        scribe?.cancel()
        apple?.cancel()
        scribe = nil
        apple = nil
    }
}

/// Apple's own speech recognition — on the device when it can be.
@MainActor
final class AppleDictation {
    enum Failure: Error {
        case notAllowed
        case unavailable
    }

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    /// What has been heard so far.
    private(set) var text = ""
    /// What was said before the utterance being heard now: the recogniser,
    /// after a pause, starts each utterance afresh — what it reports is then
    /// that alone.
    private var before = ""
    /// The utterance being heard now, as last reported.
    private var utterance = ""
    /// An utterance just ended: the next report may start another.
    private var utteranceEnded = false
    private var finished: CheckedContinuation<Void, Never>?
    private var isFinal = false

    /// Listening, from now: `heard` told what has been said so far.
    func start(heard: @escaping @MainActor (String) -> Void) throws {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { throw Failure.notAllowed }
        guard let recognizer = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer(), recognizer.isAvailable else {
            throw Failure.unavailable
        }
        self.recognizer = recognizer
        text = ""
        before = ""
        utterance = ""
        utteranceEnded = false
        isFinal = false
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // No microphone to hear with — a simulator without one: said, not crashed on.
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.unavailable }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        engine.prepare()
        try engine.start()
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let said = result?.bestTranscription.formattedString
            // Told how it was said: the utterance is over.
            let ended = result?.speechRecognitionMetadata != nil
            let final = result?.isFinal == true || error != nil
            DispatchQueue.main.async {
                guard let self else { return }
                if let said {
                    self.take(said, ended: ended)
                    heard(self.text)
                }
                if final { self.end() }
            }
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
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
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
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// What the recogniser reports, added to what came before it: a report
    /// that starts over — after an utterance ended, or one much shorter that
    /// doesn't begin as the last did — is a new utterance, the last kept.
    private func take(_ said: String, ended: Bool) {
        let continues = Self.opening(said) == Self.opening(utterance) || utterance.isEmpty
        if !continues, utteranceEnded || said.count < utterance.count / 2 {
            before = Self.join(before, utterance)
        }
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
