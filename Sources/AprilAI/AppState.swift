import AppKit
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var selectedTab: WorkspaceTab = .chat
    @Published var messages: [ChatMessage] = [
        ChatMessage(
            role: .system,
            content: "Online. Add your Gemini API key, drop files into `context/inbox`, index them, then ask something worth oxygen."
        )
    ]
    @Published var settings = AppSettings()
    @Published var apiKeyInput = ""
    @Published var draft = ""
    @Published var researchTopic = ""
    @Published var pendingMemory = ""
    @Published var memoryCandidates: [MemoryCandidate] = []
    @Published var sessionMemoryTitle = ""
    @Published var sessionMemorySummary = ""
    @Published var memorySearchQuery = ""
    @Published var memorySearchResults: [MemorySearchResult] = []
    @Published var status = "Ready."
    @Published var isBusy = false
    @Published var isLiveScreenSharing = false

    let context: ContextLibrary
    let speech = SpeechService()
    let voiceRecorder = VoiceRecorder()
    let liveSession = GeminiLiveSession()

    private let keychain = KeychainStore()
    private var liveScreenShareTask: Task<Void, Never>?
    private var autoMemoryTask: Task<Void, Never>?
    private var sessionTurns: [SessionTurn] = []
    private var lastAutoMemoryTurnCount = 0
    private var isAutoSavingMemory = false

    init() {
        let loadedSettings = AppSettings.load()
        self.settings = loadedSettings

        do {
            let contextRoot = loadedSettings.contextFolderPath.isEmpty ? nil : URL(fileURLWithPath: loadedSettings.contextFolderPath)
            self.context = try ContextLibrary(rootURL: contextRoot)
            self.settings.contextFolderPath = context.rootURL.path
        } catch {
            fatalError("Could not create context library: \(error.localizedDescription)")
        }

        apiKeyInput = keychain.readAPIKey()
        settings.apiKeyStored = !apiKeyInput.isEmpty
        settings.save()
        configureLiveSessionCallbacks()
    }

    func saveSettings(
        apiKey: String,
        model: String,
        liveModel: String,
        speakReplies: Bool,
        useGoogleSearchForResearch: Bool
    ) {
        do {
            apiKeyInput = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            settings.model = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? AppSettings.defaultTextModel
                : model.trimmingCharacters(in: .whitespacesAndNewlines)
            settings.liveModel = liveModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? AppSettings.defaultLiveModel
                : liveModel.trimmingCharacters(in: .whitespacesAndNewlines)
            settings.speakReplies = speakReplies
            settings.useGoogleSearchForResearch = useGoogleSearchForResearch
            settings.contextFolderPath = context.rootURL.path

            try keychain.saveAPIKey(apiKeyInput)
            settings.apiKeyStored = !apiKeyInput.isEmpty
            settings.save()
            status = "Settings saved."
        } catch {
            status = error.localizedDescription
        }
    }

    func openContextFolder() {
        NSWorkspace.shared.open(context.rootURL)
    }

    func chooseContextFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try context.updateRootURL(url)
                settings.contextFolderPath = url.path
                settings.save()
                status = "Context folder changed."
            } catch {
                status = error.localizedDescription
            }
        }
    }

    func indexContext() {
        Task {
            isBusy = true
            status = "Indexing context/inbox..."
            await context.reindexInbox()
            status = context.lastIndexSummary
            isBusy = false
        }
    }

    func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        send(text)
    }

    func send(_ text: String, includeScreen: Bool = false) {
        appendMessage(ChatMessage(role: .user, content: text))

        Task {
            await self.runBusy("Thinking...") {
                let references = self.context.search(text)
                let queryEmbedding = try? await self.gemini().embedText(
                    text,
                    title: "User query",
                    isQuery: true,
                    embeddingModel: self.settings.embeddingModel,
                    dimensions: self.settings.embeddingDimensions
                )
                let memoryResults = self.context.searchMemories(text, embedding: queryEmbedding, limit: 6)
                let prompt = Prompts.chat(userPrompt: text, references: references, memories: memoryResults)
                let image = includeScreen ? try await ScreenCaptureService.captureMainDisplayPNG() : nil
                let answer = try await self.gemini().generateText(
                    system: Prompts.system,
                    prompt: prompt,
                    imagePNG: image
                )
                let reply = AssistantReply.parse(answer)
                let displayedReferences = references + memoryResults.map {
                    ContextReference(source: "Memory: \($0.item.type.label)", snippet: $0.item.content)
                }

                self.appendMessage(ChatMessage(
                    role: .assistant,
                    content: reply.answer,
                    spokenSummary: reply.speakable,
                    references: displayedReferences
                ))
                if self.settings.speakReplies {
                    await self.speakWithGemini(reply.speakable)
                }
            }
        }
    }

    func lookAtScreen() {
        send("Look at my screen and explain what matters. Challenge any obvious bad assumption or next-step confusion.", includeScreen: true)
    }

    func startOrStopVoice() {
        Task {
            await startOrStopLiveVoice()
        }
    }

    func toggleLiveScreenShare() {
        Task {
            await startOrStopLiveScreenShare()
        }
    }

    func connectLiveIfNeeded() async {
        guard !liveSession.isConnected else { return }
        do {
            status = "Opening Live session..."
            try await liveSession.connect(
                apiKey: apiKeyInput,
                model: settings.liveModel,
                voice: settings.ttsVoice,
                systemInstruction: Prompts.system + "\n\nFor live voice, keep spoken replies concise unless the user asks for depth. Challenge weak thinking, but do it quickly. If video frames arrive, treat them as the user's current screen and use them as live visual context. Approved long-term memories may be injected as background context; use them as fallible hints, not unquestionable truth."
            )
            try? await refreshLiveMemoryContext(silent: true)
        } catch {
            messages.append(ChatMessage(role: .system, content: error.localizedDescription))
            status = error.localizedDescription
        }
    }

    func refreshLiveMemoryContext(silent: Bool = false) async throws {
        guard liveSession.isConnected else {
            if !silent {
                status = "Live is not connected yet."
            }
            return
        }

        let packet = context.liveMemoryPacket()
        try await liveSession.sendMemoryContext(packet)
        if !silent {
            status = "Live memory context refreshed."
        }
    }

    func refreshLiveMemoryContextButton() {
        Task {
            do {
                try await refreshLiveMemoryContext()
            } catch {
                messages.append(ChatMessage(role: .system, content: error.localizedDescription))
                status = error.localizedDescription
            }
        }
    }

    func startOrStopLiveVoice() async {
        let shouldInterruptAssistant = speech.isSpeaking && !liveSession.isStreamingMic
        if shouldInterruptAssistant {
            stopSpeech()
            status = "Interrupted assistant. Listening..."
        }

        await connectLiveIfNeeded()
        guard liveSession.isConnected else { return }

        do {
            if shouldInterruptAssistant {
                try await liveSession.startMic()
            } else {
                try await liveSession.toggleMic()
            }
        } catch {
            messages.append(ChatMessage(role: .system, content: error.localizedDescription))
            status = error.localizedDescription
        }
    }

    func startOrStopLiveScreenShare() async {
        if isLiveScreenSharing {
            stopLiveScreenShare()
            return
        }

        await connectLiveIfNeeded()
        guard liveSession.isConnected else { return }

        isLiveScreenSharing = true
        status = "Live screen sharing started."

        liveScreenShareTask?.cancel()
        liveScreenShareTask = Task { [weak self] in
            guard let self else { return }
            await self.runLiveScreenShareLoop()
        }
    }

    func disconnectLive() {
        stopLiveScreenShare(notify: false)
        liveSession.disconnect()
        speech.stop()
    }

    func stopSpeech() {
        speech.stop()
        liveSession.setOutputSuppression(false)
        status = liveSession.isConnected ? "Speech stopped. Live ready." : "Speech stopped."
    }

    func stopVoiceAndAsk() {
        Task {
            await self.runBusy("Analyzing voice...") {
                let audio = try self.voiceRecorder.stop()
                let prompt = """
                The attached audio is the user's spoken request. Transcribe it mentally, answer it, and challenge weak reasoning.
                If the user asked for an action, provide read-only recommendations instead.
                Return strict JSON only:
                {
                  "speakable": "A maximum two-sentence spoken response. Keep it simple and useful.",
                  "answer": "The full Markdown answer for the app."
                }
                """
                let answer = try await self.gemini().generateText(
                    system: Prompts.system,
                    prompt: prompt,
                    audioMIMEType: "audio/mp4",
                    audioData: audio
                )
                let reply = AssistantReply.parse(answer)
                self.appendMessage(ChatMessage(
                    role: .assistant,
                    content: reply.answer,
                    spokenSummary: reply.speakable
                ))
                if self.settings.speakReplies {
                    await self.speakWithGemini(reply.speakable)
                }
            }
        }
    }

    func savePendingMemory() {
        let text = pendingMemory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        Task {
            await self.runBusy("Saving memory...") {
                let embedding = try? await self.embeddingForMemory(content: text, title: "Manual memory")
                try self.context.saveMemory(
                    text,
                    embedding: embedding,
                    embeddingModel: self.settings.embeddingModel,
                    dimensions: self.settings.embeddingDimensions
                )
                self.pendingMemory = ""
                let savedStatus = embedding == nil
                    ? "Memory saved without embedding."
                    : "Memory saved and embedded."
                let refreshedLive = await self.refreshLiveMemoryAfterMemoryChange()
                self.status = refreshedLive ? "\(savedStatus) Live memory refreshed." : savedStatus
            }
        }
    }

    func reviewSessionMemory() {
        let transcript = sessionTranscriptForMemory()
        guard !transcript.isEmpty else {
            status = "No user/assistant session turns to review yet."
            return
        }

        Task {
            await self.runBusy("Drafting session memory...") {
                let raw = try await self.gemini().generateText(
                    system: Prompts.system,
                    prompt: Prompts.sessionMemoryReview(transcript: transcript)
                )
                let review = try SessionMemoryReview.parse(raw)
                self.sessionMemoryTitle = review.title
                self.sessionMemorySummary = review.summary
                self.memoryCandidates = review.candidates.filter {
                    !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                self.selectedTab = .memory
                self.status = self.memoryCandidates.isEmpty
                    ? "No durable memories found in this session."
                    : "Drafted \(self.memoryCandidates.count) memory candidate\(self.memoryCandidates.count == 1 ? "" : "s")."
            }
        }
    }

    func saveSelectedMemoryCandidates() {
        let selected = memoryCandidates.filter { $0.isSelected }
        guard !selected.isEmpty else {
            status = "Select at least one memory candidate."
            return
        }

        Task {
            await self.runBusy("Saving reviewed memories...") {
                var embeddings: [UUID: [Float]] = [:]
                for candidate in selected {
                    if let embedding = try? await self.embeddingForMemory(
                        content: candidate.content,
                        title: "\(candidate.type.label) memory"
                    ) {
                        embeddings[candidate.id] = embedding
                    }
                }

                try self.context.saveReviewedMemories(
                    candidates: selected,
                    sessionTitle: self.sessionMemoryTitle.isEmpty ? "Reviewed session" : self.sessionMemoryTitle,
                    sessionSummary: self.sessionMemorySummary,
                    embeddings: embeddings,
                    embeddingModel: self.settings.embeddingModel,
                    dimensions: self.settings.embeddingDimensions
                )

                let savedIDs = Set(selected.map(\.id))
                self.memoryCandidates.removeAll { savedIDs.contains($0.id) }
                let savedStatus = embeddings.count == selected.count
                    ? "Saved and embedded \(selected.count) memor\(selected.count == 1 ? "y" : "ies")."
                    : "Saved \(selected.count) memor\(selected.count == 1 ? "y" : "ies"); some embeddings failed gracefully."
                let refreshedLive = await self.refreshLiveMemoryAfterMemoryChange()
                self.status = refreshedLive ? "\(savedStatus) Live memory refreshed." : savedStatus
            }
        }
    }

    func skipSelectedMemoryCandidates() {
        let selectedIDs = Set(memoryCandidates.filter { $0.isSelected }.map(\.id))
        guard !selectedIDs.isEmpty else {
            status = "Select at least one memory candidate to skip."
            return
        }
        memoryCandidates.removeAll { selectedIDs.contains($0.id) }
        status = "Skipped selected memory candidates."
    }

    func deleteMemory(_ memory: MemoryItem) {
        do {
            try context.deleteMemory(memory)
            memorySearchResults.removeAll { $0.item.id == memory.id }
            status = "Deleted memory."
            Task {
                if await refreshLiveMemoryAfterMemoryChange(), status == "Deleted memory." {
                    status = "Deleted memory. Live memory refreshed."
                }
            }
        } catch {
            messages.append(ChatMessage(role: .system, content: error.localizedDescription))
            status = error.localizedDescription
        }
    }

    func runMemorySearch() {
        let query = memorySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            memorySearchResults = []
            return
        }

        Task {
            let embedding = try? await self.gemini().embedText(
                query,
                title: "Memory search",
                isQuery: true,
                embeddingModel: self.settings.embeddingModel,
                dimensions: self.settings.embeddingDimensions
            )
            self.memorySearchResults = self.context.searchMemories(query, embedding: embedding, limit: 10)
            self.status = self.memorySearchResults.isEmpty
                ? "No memory matches."
                : "Found \(self.memorySearchResults.count) memory match\(self.memorySearchResults.count == 1 ? "" : "es")."
        }
    }

    func runResearch() {
        let topic = researchTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty else { return }

        Task {
            await self.runBusy("Running research...") {
                let references = self.context.search(topic, limit: 8)
                let report = try await self.gemini().generateText(
                    system: Prompts.system,
                    prompt: Prompts.research(topic: topic, references: references),
                    useGoogleSearch: self.settings.useGoogleSearchForResearch
                )
                let saved = try self.context.saveResearch(topic: topic, markdown: report)
                self.appendMessage(
                    ChatMessage(
                        role: .assistant,
                        content: "Research report saved:\n\n\(saved.path)\n\n\(report)",
                        references: references
                    )
                )
                self.selectedTab = .research
                self.researchTopic = ""
            }
        }
    }

    private func gemini() -> GeminiClient {
        GeminiClient(apiKey: apiKeyInput, model: settings.model)
    }

    private func configureLiveSessionCallbacks() {
        liveSession.onStatus = { [weak self] message in
            Task { @MainActor in self?.status = message }
        }

        speech.onOutputActivityChanged = { [weak self] active in
            Task { @MainActor in self?.liveSession.setOutputSuppression(active) }
        }

        liveSession.onAudio = { [weak self] pcm in
            Task { @MainActor in self?.speech.enqueueLivePCM16(pcm) }
        }

        liveSession.onInterrupted = { [weak self] in
            Task { @MainActor in
                self?.speech.stop()
                self?.status = "Live interrupted. Listening for the new turn."
            }
        }

        liveSession.onTranscript = { [weak self] role, text in
            Task { @MainActor in
                guard let self else { return }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                if role == "Assistant" {
                    self.appendMessage(ChatMessage(
                        role: .assistant,
                        content: trimmed,
                        spokenSummary: AssistantReply.shortSpeakable(from: trimmed)
                    ))
                } else if role == "You" {
                    guard !self.speech.isSpeaking else { return }
                    self.appendMessage(ChatMessage(role: .user, content: trimmed))
                }
            }
        }

        liveSession.onError = { [weak self] message in
            Task { @MainActor in
                self?.stopLiveScreenShare(notify: false)
                self?.messages.append(ChatMessage(role: .system, content: message))
            }
        }
    }

    func speakLastAssistantMessage() {
        guard let last = messages.last(where: { $0.role == .assistant }) else { return }
        Task {
            let text = last.spokenSummary.isEmpty ? AssistantReply.shortSpeakable(from: last.content) : last.spokenSummary
            await speakWithGemini(text)
        }
    }

    private func speakWithGemini(_ text: String) async {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        do {
            let audio = try await gemini().generateSpeech(
                text: cleaned,
                ttsModel: settings.ttsModel,
                voiceName: settings.ttsVoice
            )
            try speech.playAudio(audio)
        } catch {
            status = "Gemini speech failed: \(error.localizedDescription)"
            speech.speak(cleaned)
        }
    }

    private func embeddingForMemory(content: String, title: String) async throws -> [Float] {
        try await gemini().embedText(
            content,
            title: title,
            isQuery: false,
            embeddingModel: settings.embeddingModel,
            dimensions: settings.embeddingDimensions
        )
    }

    @discardableResult
    private func refreshLiveMemoryAfterMemoryChange() async -> Bool {
        guard liveSession.isConnected else { return false }

        do {
            try await refreshLiveMemoryContext(silent: true)
            return true
        } catch {
            messages.append(ChatMessage(role: .system, content: "Live memory refresh failed: \(error.localizedDescription)"))
            return false
        }
    }

    private func appendMessage(_ message: ChatMessage) {
        messages.append(message)
        if message.role == .user || message.role == .assistant {
            recordSessionTurn(role: message.role, content: message.content)
        }
    }

    private func recordSessionTurn(role: ChatRole, content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sessionTurns.append(SessionTurn(role: role, content: trimmed, createdAt: Date()))
        if sessionTurns.count > 80 {
            let overflow = sessionTurns.count - 80
            sessionTurns.removeFirst(overflow)
            lastAutoMemoryTurnCount = max(0, lastAutoMemoryTurnCount - overflow)
        }

        if role == .assistant {
            scheduleAutoMemoryExtraction()
        }
    }

    private func sessionTranscriptForMemory() -> String {
        sessionTurns
            .suffix(60)
            .map { turn in
                let role = turn.role == .user ? "User" : "Assistant"
                return "\(role): \(turn.content)"
            }
            .joined(separator: "\n\n")
    }

    private func runLiveScreenShareLoop() async {
        var consecutiveFailures = 0

        while !Task.isCancelled {
            do {
                if !liveSession.isConnected {
                    await connectLiveIfNeeded()
                    guard liveSession.isConnected else {
                        throw GeminiError.badResponse("Live screen sharing stopped because Live could not reconnect.")
                    }
                    try? await refreshLiveMemoryContext(silent: true)
                }

                let frame = try await ScreenCaptureService.captureMainDisplayJPEG(maxDimension: 1280, compression: 0.72)
                try await liveSession.sendVideoFrame(frame, mimeType: "image/jpeg")
                consecutiveFailures = 0
                if !liveSession.isConnected {
                    break
                }
            } catch is CancellationError {
                break
            } catch {
                consecutiveFailures += 1
                status = "Live screen frame failed (\(consecutiveFailures)/3): \(error.localizedDescription)"

                if consecutiveFailures >= 3 {
                    messages.append(ChatMessage(role: .system, content: error.localizedDescription))
                    stopLiveScreenShare(notify: false)
                    status = error.localizedDescription
                    break
                }
            }

            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                break
            }
        }
    }

    private func scheduleAutoMemoryExtraction() {
        guard !apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard sessionTurns.count - lastAutoMemoryTurnCount >= 4 else { return }

        autoMemoryTask?.cancel()
        autoMemoryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 8_000_000_000)
            } catch {
                return
            }
            await self?.autoSaveSessionMemoryIfNeeded()
        }
    }

    private func autoSaveSessionMemoryIfNeeded() async {
        guard !isAutoSavingMemory else { return }
        guard !apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let currentTurnCount = sessionTurns.count
        guard currentTurnCount - lastAutoMemoryTurnCount >= 4 else { return }

        let transcript = sessionTurns
            .suffix(24)
            .map { turn in
                let role = turn.role == .user ? "User" : "Assistant"
                return "\(role): \(turn.content)"
            }
            .joined(separator: "\n\n")
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        isAutoSavingMemory = true
        defer { isAutoSavingMemory = false }

        do {
            let raw = try await gemini().generateText(
                system: Prompts.system,
                prompt: Prompts.sessionMemoryAutoSave(transcript: transcript)
            )
            let review = try SessionMemoryReview.parse(raw)
            let candidates = uniqueAutoMemoryCandidates(from: review.candidates)

            guard !candidates.isEmpty else {
                lastAutoMemoryTurnCount = currentTurnCount
                status = "Auto memory checked; nothing durable to save."
                return
            }

            var embeddings: [UUID: [Float]] = [:]
            for candidate in candidates {
                if let embedding = try? await embeddingForMemory(
                    content: candidate.content,
                    title: "\(candidate.type.label) memory"
                ) {
                    embeddings[candidate.id] = embedding
                }
            }

            try context.saveReviewedMemories(
                candidates: candidates,
                sessionTitle: review.title.isEmpty ? "Auto memory" : review.title,
                sessionSummary: review.summary,
                embeddings: embeddings,
                embeddingModel: settings.embeddingModel,
                dimensions: settings.embeddingDimensions
            )

            lastAutoMemoryTurnCount = currentTurnCount
            let refreshedLive = await refreshLiveMemoryAfterMemoryChange()
            status = refreshedLive
                ? "Auto-saved \(candidates.count) memor\(candidates.count == 1 ? "y" : "ies"). Live memory refreshed."
                : "Auto-saved \(candidates.count) memor\(candidates.count == 1 ? "y" : "ies")."
        } catch {
            messages.append(ChatMessage(role: .system, content: "Auto memory failed: \(error.localizedDescription)"))
            status = "Auto memory failed: \(error.localizedDescription)"
        }
    }

    private func uniqueAutoMemoryCandidates(from candidates: [MemoryCandidate]) -> [MemoryCandidate] {
        var seen = Set(context.memories.map { normalizedMemoryText($0.content) })
        return candidates.compactMap { candidate in
            let content = candidate.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }
            guard candidate.sensitivity.lowercased() != "high" else { return nil }

            let normalized = normalizedMemoryText(content)
            guard !normalized.isEmpty, !seen.contains(normalized) else { return nil }
            seen.insert(normalized)

            var cleaned = candidate
            cleaned.content = content
            cleaned.summary = cleaned.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            cleaned.isSelected = true
            return cleaned
        }
    }

    private func normalizedMemoryText(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stopLiveScreenShare(notify: Bool = true) {
        liveScreenShareTask?.cancel()
        liveScreenShareTask = nil
        guard isLiveScreenSharing else { return }
        isLiveScreenSharing = false
        if notify {
            status = liveSession.isConnected ? "Live screen sharing stopped." : "Live screen sharing ended."
        }
    }

    private func runBusy(_ busyStatus: String, operation: @escaping () async throws -> Void) async {
        isBusy = true
        status = busyStatus
        do {
            try await operation()
            if status == busyStatus {
                status = "Done."
            }
        } catch {
            messages.append(ChatMessage(role: .system, content: error.localizedDescription))
            status = error.localizedDescription
        }
        isBusy = false
    }
}

private struct SessionTurn {
    let role: ChatRole
    let content: String
    let createdAt: Date
}

struct AssistantReply: Codable {
    let speakable: String
    let answer: String

    static func parse(_ raw: String) -> AssistantReply {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = stripMarkdownFence(trimmed)

        if
            let data = cleaned.data(using: .utf8),
            let reply = try? JSONDecoder().decode(AssistantReply.self, from: data)
        {
            return AssistantReply(
                speakable: shortSpeakable(from: reply.speakable),
                answer: reply.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        if
            let start = cleaned.firstIndex(of: "{"),
            let end = cleaned.lastIndex(of: "}")
        {
            let json = String(cleaned[start...end])
            if
                let data = json.data(using: .utf8),
                let reply = try? JSONDecoder().decode(AssistantReply.self, from: data)
            {
                return AssistantReply(
                    speakable: shortSpeakable(from: reply.speakable),
                    answer: reply.answer.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        }

        return AssistantReply(speakable: shortSpeakable(from: raw), answer: raw)
    }

    static func shortSpeakable(from text: String) -> String {
        let noMarkdown = text
            .replacingOccurrences(of: #"(?s)```.*?```"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[#>*_`]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\[[^\]]+\]\([^)]+\)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let sentences = noMarkdown
            .components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(2)

        let joined = sentences.joined(separator: ". ")
        if joined.count <= 180 {
            return joined.isEmpty ? "I have the full answer in chat." : joined
        }
        return String(joined.prefix(177)) + "..."
    }

    private static func stripMarkdownFence(_ text: String) -> String {
        var cleaned = text
        if cleaned.hasPrefix("```json") {
            cleaned.removeFirst("```json".count)
        } else if cleaned.hasPrefix("```") {
            cleaned.removeFirst("```".count)
        }
        if cleaned.hasSuffix("```") {
            cleaned.removeLast(3)
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension SessionMemoryReview {
    static func parse(_ raw: String) throws -> SessionMemoryReview {
        let cleaned = stripMarkdownFence(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        let json = extractJSONObject(from: cleaned)

        guard
            let data = json.data(using: .utf8),
            var review = try? JSONDecoder().decode(SessionMemoryReview.self, from: data)
        else {
            throw MemoryReviewError.invalidJSON
        }

        review.title = review.title.trimmingCharacters(in: .whitespacesAndNewlines)
        review.summary = review.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        review.candidates = review.candidates.map { candidate in
            var cleaned = candidate
            cleaned.content = cleaned.content.trimmingCharacters(in: .whitespacesAndNewlines)
            cleaned.summary = cleaned.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            cleaned.evidence = cleaned.evidence.trimmingCharacters(in: .whitespacesAndNewlines)
            cleaned.sensitivity = cleaned.sensitivity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "low"
                : cleaned.sensitivity.trimmingCharacters(in: .whitespacesAndNewlines)
            cleaned.confidence = min(1, max(0, cleaned.confidence))
            cleaned.importance = min(1, max(0, cleaned.importance))
            cleaned.isSelected = cleaned.sensitivity.lowercased() != "high"
            return cleaned
        }
        return review
    }

    private static func stripMarkdownFence(_ text: String) -> String {
        var cleaned = text
        if cleaned.hasPrefix("```json") {
            cleaned.removeFirst("```json".count)
        } else if cleaned.hasPrefix("```") {
            cleaned.removeFirst("```".count)
        }
        if cleaned.hasSuffix("```") {
            cleaned.removeLast(3)
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractJSONObject(from text: String) -> String {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else {
            return text
        }
        return String(text[start...end])
    }
}

enum MemoryReviewError: LocalizedError {
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            "Could not parse Gemini's memory review JSON. Try reviewing the session again."
        }
    }
}
