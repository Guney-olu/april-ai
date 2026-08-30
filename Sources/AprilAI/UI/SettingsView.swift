import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var apiKeyDraft = ""
    @State private var modelDraft = AppSettings.defaultTextModel
    @State private var liveModelDraft = AppSettings.defaultLiveModel
    @State private var speakRepliesDraft = true
    @State private var searchGroundingDraft = true
    @State private var showAPIKey = false
    @State private var localSettingsDraft = LocalModelSettings()
    @State private var localAPIKeyDraft = ""
    @State private var showLocalAPIKey = false
    @State private var cartesiaAPIKeyDraft = ""
    @State private var showCartesiaAPIKey = false
    @State private var didLoadDrafts = false

    private let textModels = [
        "gemini-3.1-flash-lite",
        "gemini-3-flash-preview",
        "gemini-3.1-pro-preview",
        "gemini-3.5-flash",
        "gemini-3.5-pro",
        "gemini-3.0-flash",
        "gemini-2.5-flash",
        "gemini-2.5-pro",
        "gemini-2.0-flash"
    ]

    private let liveModels = [
        "gemini-3.1-flash-live-preview",
        "gemini-live-2.5-flash-preview",
        "gemini-2.0-flash-live-001"
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                GroupBox("Gemini") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("API key")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        HStack {
                            AppKitTextInput(
                                text: $apiKeyDraft,
                                placeholder: "AIza...",
                                isSecure: !showAPIKey
                            )
                            .frame(height: 28)

                            Button(showAPIKey ? "Hide" : "Show") {
                                showAPIKey.toggle()
                            }
                        }

                        HStack {
                            Button("Paste Clipboard") {
                                pasteAPIKeyFromClipboard()
                            }
                            Button("Enter in Dialog") {
                                enterAPIKeyInDialog()
                            }
                            Button("Use Env Key") {
                                useEnvironmentAPIKey()
                            }
                        }
                        .buttonStyle(.bordered)

                        Text("Text model")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Picker("Text model", selection: $modelDraft) {
                            ForEach(textModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)

                        Text("Live model")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Picker("Live model", selection: $liveModelDraft) {
                            ForEach(liveModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)

                        HStack {
                            Button("Default text") { modelDraft = AppSettings.defaultTextModel }
                            Button("Default live") { liveModelDraft = AppSettings.defaultLiveModel }
                        }
                        .buttonStyle(.bordered)

                        Text("Teacher model")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(AppSettings.defaultTeacherModel)
                                .font(.callout.monospaced())
                            Text("Used only when Live escalates complex local-control planning, coordinate recovery, or failed tool attempts.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text("Vision locator model")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(AppSettings.defaultVisionModel)
                                .font(.callout.monospaced())
                            Text("Used by move_mouse_to_target to read the gridded screenshot and choose where the cursor should move.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text("Computer Use autopilot")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(AppSettings.defaultComputerUseModel), policy: Run until risky, max \(AppSettings.defaultComputerUseMaxSteps) steps")
                                .font(.callout.monospaced())
                            Text("Used only when Live explicitly starts a visual UI-control or form-filling loop. It pauses before send, buy, delete, submit, secrets, or security changes.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Divider()

                        Text("Memory embeddings")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(state.settings.embeddingModel), \(state.settings.embeddingDimensions) dimensions")
                                .font(.callout.monospaced())
                            Text("Memory policy: review first. Approved memories are stored locally; Gemini is used only to draft candidates and generate embeddings.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Button("Save Gemini Settings") {
                            state.saveSettings(
                                apiKey: apiKeyDraft,
                                model: modelDraft,
                                liveModel: liveModelDraft,
                                speakReplies: speakRepliesDraft,
                                useGoogleSearchForResearch: searchGroundingDraft
                            )
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(10)
                }

                GroupBox("Local Model") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Enable Local tab", isOn: $localSettingsDraft.isEnabled)

                        Text("Unsloth API key")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        HStack {
                            AppKitTextInput(
                                text: $localAPIKeyDraft,
                                placeholder: "sk-unsloth-...",
                                isSecure: !showLocalAPIKey
                            )
                            .frame(height: 28)
                            Button(showLocalAPIKey ? "Hide" : "Show") { showLocalAPIKey.toggle() }
                        }

                        endpointField("Unsloth base URL", text: $localSettingsDraft.unslothBaseURL)
                        endpointField("Local model", text: $localSettingsDraft.model)
                        Text("Cartesia API key")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        HStack {
                            AppKitTextInput(
                                text: $cartesiaAPIKeyDraft,
                                placeholder: "sk_car_...",
                                isSecure: !showCartesiaAPIKey
                            )
                            .frame(height: 28)
                            Button(showCartesiaAPIKey ? "Hide" : "Show") { showCartesiaAPIKey.toggle() }
                        }
                        endpointField("Cartesia model", text: $localSettingsDraft.cartesiaModel)
                        endpointField("Cartesia voice ID", text: $localSettingsDraft.cartesiaVoiceID)

                        Text("Voice input uses macOS Speech Recognition. Sonic speech uses Cartesia's API directly, so there is no local TTS server or model download.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text("Local chat always enables the Unsloth server's web search, Python, and terminal tools. Those tools run on that server; they do not receive April's macOS control permissions.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack {
                            Button("Use Local Defaults") {
                                localSettingsDraft = LocalModelSettings()
                            }
                            Button("Test Local Services") {
                                state.saveLocalSettings(localSettingsDraft, apiKey: localAPIKeyDraft, cartesiaAPIKey: cartesiaAPIKeyDraft)
                                state.testLocalServices()
                            }
                            Button("Save Local Settings") {
                                state.saveLocalSettings(localSettingsDraft, apiKey: localAPIKeyDraft, cartesiaAPIKey: cartesiaAPIKeyDraft)
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        ForEach(state.localServiceHealth) { health in
                            HStack(spacing: 7) {
                                Image(systemName: health.isReachable ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(health.isReachable ? .green : .secondary)
                                Text(health.service.rawValue)
                                    .font(.caption.weight(.semibold))
                                Text(health.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(10)
                }

                GroupBox("Behavior") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Speak short replies", isOn: $speakRepliesDraft)
                        Toggle("Use Google Search grounding in research mode", isOn: $searchGroundingDraft)

                        Text("Gemini chat uses \(AppSettings.defaultTTSModel) with the \(AppSettings.defaultTTSVoice) voice. Local chat sends its short reply to Cartesia Sonic. Full answers stay in chat.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button("Save Behavior") {
                            state.saveSettings(
                                apiKey: apiKeyDraft,
                                model: modelDraft,
                                liveModel: liveModelDraft,
                                speakReplies: speakRepliesDraft,
                                useGoogleSearchForResearch: searchGroundingDraft
                            )
                        }
                    }
                    .padding(10)
                }

                GroupBox("Context") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(state.context.rootURL.path)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)

                        HStack {
                            Button("Open") {
                                state.openContextFolder()
                            }
                            Button("Open Logs") {
                                state.openLogsFolder()
                            }
                            Button("Choose") {
                                state.chooseContextFolder()
                            }
                        }
                    }
                    .padding(10)
                }

                GroupBox("Local Control") {
                    VStack(alignment: .leading, spacing: 12) {
                        permissionHeader(
                            title: "Accessibility",
                            granted: state.accessibilityTrusted
                        )

                        Text("April AI can use Live tools for native app Accessibility control, app opening, mouse movement, clicks, scrolling, typing, and a small key allowlist. Local-control tools execute without an extra approval dialog once the required macOS permission is active.")
                            .foregroundStyle(.secondary)

                        Text("It still cannot delete files, run shell commands, send messages, buy things, schedule events, type secrets, or complete irreversible workflows for you.")
                            .foregroundStyle(.secondary)

                        HStack {
                            Button("Request Accessibility Permission") {
                                state.requestAccessibilityPermission()
                            }
                            Button("Refresh Status") {
                                state.refreshPermissionStatus()
                            }
                        }
                        .buttonStyle(.bordered)

                        Divider()

                        permissionHeader(
                            title: "Screen Recording",
                            granted: state.screenCaptureTrusted
                        )

                        Text("Screen sharing and Look at screen need macOS Screen & System Audio Recording permission. After changing this permission, quit and reopen April AI so macOS reloads it.")
                            .foregroundStyle(.secondary)

                        HStack {
                            Button("Request Screen Permission") {
                                state.requestScreenCapturePermission()
                            }
                            Button("Open Privacy Settings") {
                                state.openScreenCaptureSettings()
                            }
                            Button("Refresh Status") {
                                state.refreshPermissionStatus()
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(10)
                }
            }
            .padding(18)
        }
        .onAppear {
            state.refreshPermissionStatus()
            guard !didLoadDrafts else { return }
            apiKeyDraft = state.apiKeyInput
            modelDraft = state.settings.model
            liveModelDraft = state.settings.liveModel
            speakRepliesDraft = state.settings.speakReplies
            searchGroundingDraft = state.settings.useGoogleSearchForResearch
            localSettingsDraft = state.settings.local
            localAPIKeyDraft = state.localAPIKeyInput
            cartesiaAPIKeyDraft = state.cartesiaAPIKeyInput
            didLoadDrafts = true
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Save") {
                    state.saveSettings(
                        apiKey: apiKeyDraft,
                        model: modelDraft,
                        liveModel: liveModelDraft,
                        speakReplies: speakRepliesDraft,
                        useGoogleSearchForResearch: searchGroundingDraft
                    )
                    state.saveLocalSettings(localSettingsDraft, apiKey: localAPIKeyDraft, cartesiaAPIKey: cartesiaAPIKeyDraft)
                }
            }
        }
    }

    private func permissionHeader(title: String, granted: Bool) -> some View {
        HStack {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Label(
                granted ? "Granted" : "Not granted",
                systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(granted ? .green : .orange)
        }
    }

    private func endpointField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
        }
    }

    private func pasteAPIKeyFromClipboard() {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            state.status = "Clipboard has no text."
            return
        }
        apiKeyDraft = trimmed
        state.status = "API key pasted from clipboard. Click Save."
    }

    private func enterAPIKeyInDialog() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Gemini API Key"
        alert.informativeText = "Paste or type your key here. It will be saved to Keychain only after you click Save in Settings."
        alert.addButton(withTitle: "Use Key")
        alert.addButton(withTitle: "Cancel")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 520, height: 28))
        field.placeholderString = "AIza..."
        field.stringValue = apiKeyDraft
        alert.accessoryView = field

        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
        }

        if alert.runModal() == .alertFirstButtonReturn {
            apiKeyDraft = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            state.status = "API key loaded from dialog. Click Save."
        }
    }

    private func useEnvironmentAPIKey() {
        let env = ProcessInfo.processInfo.environment
        let key = env["GEMINI_API_KEY"] ?? env["GOOGLE_API_KEY"] ?? ""
        if key.isEmpty {
            state.status = "No GEMINI_API_KEY or GOOGLE_API_KEY found in this process environment."
            return
        }
        apiKeyDraft = key.trimmingCharacters(in: .whitespacesAndNewlines)
        state.status = "API key loaded from environment. Click Save."
    }
}
