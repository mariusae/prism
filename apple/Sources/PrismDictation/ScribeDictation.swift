import AVFoundation

/// Words spoken, written down by ElevenLabs' Scribe, online: the microphone
/// streamed to it as it is heard — 16 kHz, 16-bit, mono — what it has
/// made of it so far told as it comes, and all of it when let go.
///
/// Heard from the first moment: what is said while the token is fetched
/// and the session starts is held, and sent once it has. A segment is
/// committed by the server at each pause; what is after the last pause
/// comes as a partial that may still change. Let go, the rest is
/// committed and waited for, a moment at most.
@MainActor
final class ScribeDictation {
    struct Failure: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    private let engine = AVAudioEngine()
    private var stream: ScribeStream?
    private var socket: URLSessionWebSocketTask?
    private var heard: (@MainActor (String) -> Void)?
    /// Not started after all — no token, refused, never answered: told
    /// once, so that another way can take over.
    private var onFailedToStart: (@MainActor (String) -> Void)?
    private var started = false
    /// Kept to ask again — once, without the key terms — when ElevenLabs
    /// will not take them.
    private var token: (@MainActor () async -> String?)?
    private var keyterms: [String] = []
    /// Told when the session starts: ElevenLabs is listening.
    var onStarted: (@MainActor () -> Void)?
    private var startTimeout: DispatchWorkItem?
    /// The segments committed, and the one being heard now.
    private var committed = ""
    private var partial = ""
    private(set) var text = ""
    private var stopping = false
    /// The server stopped listening, part way: what was heard is all there is.
    private var ended = false
    private var finished: CheckedContinuation<Void, Never>?
    private var settle: DispatchWorkItem?

    private static let sampleRate = 16_000.0
    /// How long the server may take to start a session, once asked,
    /// before Apple's own recognition is used instead.
    private static let startWait: TimeInterval = 2.5

    /// Listening, from now — with a single-use token from `token`, once it
    /// comes: `keyterms` — names, titles — the words to favour.
    func start(token: @escaping @MainActor () async -> String?, keyterms: [String], heard: @escaping @MainActor (String) -> Void,
               failedToStart: @escaping @MainActor (String) -> Void) throws {
        self.heard = heard
        self.token = token
        self.keyterms = keyterms
        onFailedToStart = failedToStart
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // No microphone to hear with — a simulator without one: said, not crashed on.
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure(message: "There is no microphone to hear with") }
        guard let stream = ScribeStream(from: format, sampleRate: Self.sampleRate) else {
            throw Failure(message: "The microphone’s sound could not be converted")
        }
        self.stream = stream
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in stream.send(buffer) }
        engine.prepare()
        try engine.start()
        Task { @MainActor [weak self] in
            let token = await token()
            guard let self, self.stream === stream else { return }
            guard let token else { return self.failStart("No token for ElevenLabs") }
            self.connect(token: token, keyterms: keyterms)
        }
    }

    private func connect(token: String, keyterms: [String]) {
        var url = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
        url.queryItems = [
            URLQueryItem(name: "model_id", value: "scribe_v2_realtime"),
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "audio_format", value: "pcm_16000"),
            URLQueryItem(name: "commit_strategy", value: "vad"),
        ] + keyterms.prefix(50).map { URLQueryItem(name: "keyterms", value: $0) }
        guard let address = url.url, let stream else { return failStart("No address for ElevenLabs") }
        let socket = URLSession.shared.webSocketTask(with: address)
        self.socket = socket
        socket.resume()
        receive()
        stream.attach(socket)
        let timeout = DispatchWorkItem { [weak self] in self?.failStart("ElevenLabs did not answer in time") }
        startTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.startWait, execute: timeout)
    }

    /// Let go: the rest committed, and what was said, once it is written
    /// down — waited for a moment at most; longer when the session has
    /// yet to start, what was said held for it.
    func stop() async -> String {
        stopHearing()
        guard let stream else { return result() }
        if !ended {
            stopping = true
            stream.commit()
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                finished = done
                DispatchQueue.main.asyncAfter(deadline: .now() + (started ? 2.5 : 6)) { [weak self] in self?.finish() }
            }
        }
        close()
        return result()
    }

    /// Given up on, nothing kept: another way is taking over.
    func cancel() {
        stopHearing()
        close()
    }

    private func result() -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func stopHearing() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }

    private func close() {
        startTimeout?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        stream = nil
        heard = nil
        onFailedToStart = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    // MARK: What the server says

    private func receive() {
        guard let socket else { return }
        socket.receive { [weak self] result in
            Task { @MainActor in
                guard let self, socket === self.socket else { return }
                switch result {
                case .success(.string(let text)):
                    self.handle(text)
                    self.receive()
                case .success:
                    self.receive()
                case .failure(let error):
                    self.lost(error.localizedDescription)
                }
            }
        }
    }

    private func handle(_ message: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any],
              let type = object["message_type"] as? String else { return }
        switch type {
        case "session_started":
            started = true
            startTimeout?.cancel()
            stream?.opened()
            onStarted?()
        case "partial_transcript":
            partial = object["text"] as? String ?? ""
            update()
        case "committed_transcript":
            committed = Self.join(committed, object["text"] as? String ?? "")
            partial = ""
            update()
            // Let go: once the last is in — a moment more for any after it.
            if stopping { settleSoon() }
        case "commit_throttled" where stopping:
            finish()
        default:
            if let error = object["error"] as? String { lost("\(type): \(error)") }
        }
    }

    private func update() {
        text = Self.join(committed, partial)
        heard?(text)
    }

    /// Went wrong: before the session started, another way takes over;
    /// after, what was heard is kept.
    private func lost(_ reason: String) {
        guard stream != nil else { return }
        if !started, retryWithoutTerms(reason) { return }
        if !started { return failStart(reason) }
        Dictation.note("ElevenLabs stopped listening" + ": " + reason)
        // What was heard so far, partial and all, is what was said.
        committed = text
        partial = ""
        ended = true
        stopHearing()
        finish()
    }

    /// Refused for its key terms — a title too long, say — asked again
    /// without them, with a new token: what was said is still held.
    private func retryWithoutTerms(_ reason: String) -> Bool {
        guard !keyterms.isEmpty, reason.localizedCaseInsensitiveContains("keyterm"), let token, let stream else { return false }
        Dictation.note("ElevenLabs refused the key terms; asked again without them" + ": " + reason)
        keyterms = []
        startTimeout?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        Task { @MainActor [weak self] in
            let fresh = await token()
            guard let self, self.stream === stream else { return }
            guard let fresh else { return self.failStart("No token for ElevenLabs") }
            self.connect(token: fresh, keyterms: [])
        }
        return true
    }

    private func failStart(_ reason: String) {
        guard !started, stream != nil else { return }
        // Let go already: nothing to take over from.
        if stopping {
            Dictation.note("ElevenLabs did not start" + ": " + reason)
            ended = true
            return finish()
        }
        guard let failed = onFailedToStart else { return }
        Dictation.note("ElevenLabs did not start; Apple’s recognition instead" + ": " + reason)
        onFailedToStart = nil
        cancel()
        failed(reason)
    }

    private func settleSoon() {
        settle?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finish() }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func finish() {
        settle?.cancel()
        finished?.resume()
        finished = nil
    }

    private static func join(_ a: String, _ b: String) -> String {
        let a = a.trimmingCharacters(in: .whitespaces), b = b.trimmingCharacters(in: .whitespaces)
        return a.isEmpty ? b : b.isEmpty ? a : a + " " + b
    }
}

/// The socket's sending side, from the audio thread: each buffer converted
/// to 16 kHz 16-bit mono, and sent — or held, until there is a socket and
/// its session has started.
private final class ScribeStream: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let target: AVAudioFormat
    private let lock = NSLock()
    private var socket: URLSessionWebSocketTask?
    private var isOpen = false
    private var held: [String] = []

    init?(from format: AVAudioFormat, sampleRate: Double) {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: format, to: target) else { return nil }
        self.target = target
        self.converter = converter
    }

    func attach(_ socket: URLSessionWebSocketTask) {
        lock.lock()
        self.socket = socket
        lock.unlock()
    }

    /// The session started: what was held, sent, in order.
    func opened() {
        lock.lock()
        isOpen = true
        let held = held
        self.held = []
        let socket = socket
        lock.unlock()
        for text in held { socket?.send(.string(text)) { _ in } }
    }

    func send(_ buffer: AVAudioPCMBuffer) {
        guard let audio = convert(buffer) else { return }
        message(audio.base64EncodedString(), commit: false)
    }

    /// The end of what was said: committed, to be written down now.
    func commit() { message("", commit: true) }

    private func message(_ audio: String, commit: Bool) {
        let object: [String: Any] = ["message_type": "input_audio_chunk", "audio_base_64": audio,
                                     "commit": commit, "sample_rate": Int(target.sampleRate)]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        let text = String(decoding: data, as: UTF8.self)
        lock.lock()
        guard isOpen, let socket else {
            held.append(text)
            lock.unlock()
            return
        }
        lock.unlock()
        socket.send(.string(text)) { _ in }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var given = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if given {
                status.pointee = .noDataNow
                return nil
            }
            given = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData else { return nil }
        return Data(bytes: samples[0], count: Int(out.frameLength) * MemoryLayout<Int16>.size)
    }
}
