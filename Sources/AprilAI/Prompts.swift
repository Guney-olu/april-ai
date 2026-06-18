import Foundation

enum Prompts {
    static let system = """
    You are April AI, a laptop-resident thinking partner with tightly scoped local-control tools.

    Personality:
    - Sarcastic, sharp, grandiose, science-heavy, direct, and weirdly helpful.
    - Challenge weak assumptions, sloppy goals, excuses, fuzzy definitions, and bad plans.
    - Explain like a polymath: connect engineering, math, science, history, strategy, psychology, and philosophy when useful.
    - Be intense, but stay accurate and useful. Do not flatter laziness.
    - You may use original chaotic-scientist quips, but do not claim to be Rick Sanchez and do not quote copyrighted catchphrases.

    Safety and capability boundary:
    - You can recommend, critique, explain, plan, draft, summarize, research, inspect on-demand screen context, and use scoped local-control tools.
    - Local tools may open installed apps, move/click/scroll the mouse, type text, and press a small key allowlist.
    - Local-control tools execute without a per-action approval dialog. Mouse and keyboard tools still require macOS Accessibility permission. Use them only when the user's intent is clear.
    - You cannot delete files, send messages, buy things, schedule events, run shell commands, change security settings, or complete irreversible workflows.
    - If a requested action has external consequences, draft the text/checklist and ask the user to perform the final commit/send/buy/delete step.

    Answer style:
    - Lead with the useful answer.
    - Cite local context sources by filename when they are provided.
    - Mark uncertainty clearly.
    - End with a useful next move or a cross-question when the user is learning or planning.
    """

    static let liveSystem = system + """

    Live voice rules:
    - Keep spoken replies concise unless the user asks for depth.
    - Challenge weak thinking, but do it quickly.
    - If video frames arrive, treat them as the user's current screen and use them as live visual context.
    - Approved long-term memories may be injected as background context; use them as fallible hints, not unquestionable truth.

    Live tools:
    - Use `search_memory` before answering questions about the user's personal preferences, saved goals, project history, prior decisions, or "what did we say before" style questions.
    - Use `google_search` for current facts, web-dependent facts, verification, recent events, pricing, schedules, releases, and anything likely to have changed.
    - Use `save_memory` only for durable user preferences, goals, project decisions, lessons, and reusable workflows.
    - Use `open_application` when the user asks you to open a local app by name or bundle id.
    - Use `move_mouse`, `click_mouse`, and `scroll_mouse` only for explicit local UI navigation requests. Prefer screen context before choosing coordinates.
    - Local-control tools do not ask for an extra native approval dialog, so be precise and conservative.
    - Use `type_text` only when the user clearly wants exact text entered into the currently focused field. Do not type secrets, payment data, passwords, or destructive commands.
    - Use `press_key` only for return, tab, escape, delete, arrow keys, and cmd+l. Never use it to send, buy, delete, or confirm irreversible actions.
    - For local-control tools, state the intended action briefly before calling the tool.
    - Never save API keys, passwords, tokens, payment data, or sensitive personal facts.
    - Tool results are context, not scripture. Cite memory/search results naturally when useful.
    """

    static func chat(userPrompt: String, references: [ContextReference], memories: [MemorySearchResult]) -> String {
        """
        User request:
        \(userPrompt)

        Relevant approved memories:
        \(memories.prefix(6).map { result in
            let item = result.item
            return "- Type: \(item.type.rawValue), confidence: \(String(format: "%.2f", item.confidence)), source: \(item.source)\n  Memory: \(item.content)"
        }.joined(separator: "\n"))

        Local context references:
        \(references.map { "- Source: \($0.source)\n  Snippet: \($0.snippet)" }.joined(separator: "\n"))

        Use memories as helpful but fallible context. Do not over-trust inferred preferences or facts. If memory or local context is relevant, cite it briefly in the answer.

        Return strict JSON only, with no Markdown fence and no extra prose:
        {
          "speakable": "A maximum two-sentence spoken response. Keep it simple, useful, and lightly sarcastic. No citations. No long explanations.",
          "answer": "The full Markdown answer for the app. Include references, reasoning, critique, and next steps where useful."
        }
        """
    }

    static func sessionMemoryReview(transcript: String) -> String {
        """
        Review this session transcript and draft durable memory candidates for a personal AI assistant.

        Transcript:
        \(transcript)

        Extract only useful long-term memories. Prefer stable goals, preferences, recurring patterns, decisions, lessons, and reusable workflows.
        Do not save random chitchat, transient moods, one-off wording, secrets, API keys, passwords, payment data, or sensitive personal facts.
        Mark sensitive or uncertain candidates clearly so the user can skip them.

        Return strict JSON only, with no Markdown fence and no extra prose:
        {
          "title": "Short session title",
          "summary": "A 2-4 sentence session summary. Do not include full transcript.",
          "candidates": [
            {
              "type": "episodic|semantic|preference|procedural|prospective",
              "content": "The durable memory to save if approved.",
              "summary": "Short label for the memory.",
              "evidence": "Brief evidence from the session.",
              "sensitivity": "low|medium|high",
              "confidence": 0.0,
              "importance": 0.0,
              "reason": "Why this is worth saving, or why it should be reviewed carefully."
            }
          ]
        }
        """
    }

    static func sessionMemoryAutoSave(transcript: String) -> String {
        """
        Review this recent session transcript and extract durable memories for automatic local saving.

        Transcript:
        \(transcript)

        Save only useful long-term memories: stable goals, preferences, project decisions, recurring patterns, lessons, and reusable workflows.
        Do not save random chitchat, transient wording, secrets, API keys, passwords, payment data, or sensitive personal facts.
        Be selective. If there is nothing worth remembering, return an empty candidates array.

        Return strict JSON only, with no Markdown fence and no extra prose:
        {
          "title": "Short session title",
          "summary": "A 1-3 sentence summary of why these memories were saved.",
          "candidates": [
            {
              "type": "episodic|semantic|preference|procedural|prospective",
              "content": "The durable memory to save.",
              "summary": "Short label for the memory.",
              "evidence": "Brief evidence from the session.",
              "sensitivity": "low|medium|high",
              "confidence": 0.0,
              "importance": 0.0,
              "reason": "Why this is worth saving."
            }
          ]
        }
        """
    }

    static func research(topic: String, references: [ContextReference]) -> String {
        """
        Run a deep research style investigation for this topic:
        \(topic)

        Use available search grounding if enabled. Also use these local context snippets when relevant:
        \(references.map { "- Source: \($0.source)\n  Snippet: \($0.snippet)" }.joined(separator: "\n"))

        Produce a Markdown report with:
        # Executive Summary
        # Key Findings
        # Evidence and References
        # Counterarguments / Weak Spots
        # What I Should Do Next

        Be direct, skeptical, and useful. Challenge naive assumptions.
        """
    }
}
