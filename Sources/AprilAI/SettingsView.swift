import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var apiKeyDraft = ""
    @State private var modelDraft = AppSettings.defaultTextModel
    @State private var liveModelDraft = AppSettings.defaultLiveModel
    @State private var speakRepliesDraft = true
    @State private var searchGroundingDraft = true
    @State private var showAPIKey = false
    @State private var didLoadDrafts = false

    private let textModels = [
        "gemini-3.1-flash-lite",
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

                GroupBox("Behavior") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Speak short replies with Gemini Aoede voice", isOn: $speakRepliesDraft)
                        Toggle("Use Google Search grounding in research mode", isOn: $searchGroundingDraft)

                        Text("Speech uses \(AppSettings.defaultTTSModel) with the \(AppSettings.defaultTTSVoice) voice. The app speaks only the short response; the full answer stays in chat.")
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
                            Button("Choose") {
                                state.chooseContextFolder()
                            }
                        }
                    }
                    .padding(10)
                }

                GroupBox("Confirmed Local Control") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Accessibility")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Label(
                                state.accessibilityTrusted ? "Granted" : "Not granted",
                                systemImage: state.accessibilityTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                            )
                            .foregroundStyle(state.accessibilityTrusted ? .green : .orange)
                        }

                        Text("April AI can open apps and use confirmed Live tools for mouse movement, clicks, scrolling, typing, and a small key allowlist. Every control action shows an Approve Once dialog before it runs.")
                            .foregroundStyle(.secondary)

                        Text("It still cannot delete files, run shell commands, send messages, buy things, schedule events, or complete irreversible workflows for you.")
                            .foregroundStyle(.secondary)

                        HStack {
                            Button("Request Accessibility Permission") {
                                state.requestAccessibilityPermission()
                            }
                            Button("Refresh Status") {
                                state.refreshAccessibilityTrust()
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
            state.refreshAccessibilityTrust()
            guard !didLoadDrafts else { return }
            apiKeyDraft = state.apiKeyInput
            modelDraft = state.settings.model
            liveModelDraft = state.settings.liveModel
            speakRepliesDraft = state.settings.speakReplies
            searchGroundingDraft = state.settings.useGoogleSearchForResearch
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
                }
            }
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
