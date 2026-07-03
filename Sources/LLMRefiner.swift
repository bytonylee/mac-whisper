import Foundation

/// Refines transcribed text via an OpenAI-compatible chat-completions API. The system
/// prompt is deliberately conservative and language-neutral: it only fixes obvious
/// speech-recognition errors (homophones, mis-transcribed technical terms) and otherwise
/// returns the input unchanged, preserving the speaker's original language.
enum LLMRefiner {

    private static let basePrompt = """
    You are a speech-recognition post-editor. Your only task is to fix obvious \
    speech-recognition errors. Never paraphrase, rewrite, embellish, expand, or shorten.

    Strict rules:
    1. Only correct clear speech-recognition mistakes, such as homophones / near-homophones \
    and technical terms that were mis-transcribed.
    2. If the input already looks correct, return it unchanged.
    3. Never change the speaker's meaning, tone, wording, or language. Keep the text in the \
    exact same language it was spoken in — do not translate.
    4. Never add any explanation, prefix, suffix, quotation marks, or commentary.
    5. Output only the corrected text itself, nothing else.
    """

    /// System prompt, extended with the user's glossary when one is attached.
    /// The glossary biases corrections toward the speaker's domain terms —
    /// names, products, jargon — that recognizers habitually get wrong.
    private static var systemPrompt: String {
        let glossary = Settings.shared.glossaryText
        guard !glossary.isEmpty else { return basePrompt }
        return basePrompt + """


        Glossary — terms this speaker actually uses. When a word in the input sounds like \
        (or is a plausible mis-transcription of) a glossary term, replace it with the exact \
        glossary spelling. Lines of the form "wrong -> right" map a frequent \
        mis-transcription directly to the preferred term. Never insert glossary terms that \
        were not plausibly spoken.

        \(glossary)
        """
    }

    struct RefineError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// System prompt for turning a raw meeting transcript into formal,
    /// detailed minutes. The glossary is appended so domain terms come out
    /// right. `meetingDate` (the recording timestamp) fills the 일시 field.
    private static func meetingNotesPrompt(meetingDate: String) -> String {
        var prompt = """
        You are a professional minute-taker. Turn the raw speech-to-text transcript of a \
        meeting into meeting minutes (회의록), written in the SAME language as the \
        transcript (do not translate). Localize all headings and labels to that language.

        Minimum required content — always include, as far as the transcript supports it:
        - A title and a meeting overview: date/time (use "\(meetingDate)"), the \
        attendees identifiable from the transcript, and the agenda items that were \
        discussed.
        - The discussion itself: what was talked about and by whom, with the reasons, \
        trade-offs, numbers, dates, names, examples, and concerns that were actually \
        raised.
        - Decisions that were made, and action items (with owner and due date when one \
        was mentioned).

        Beyond that minimum, choose the structure, depth, and length that best fit this \
        particular meeting. A decision meeting, a brainstorm, a status sync, and a \
        design review each deserve differently shaped minutes — organize accordingly.

        Length is not a constraint, in either direction — never shorten the minutes to \
        be tidy. Do not summarize away substance: a reader who missed the meeting must \
        be able to follow each discussion — who said what, why, what was weighed, and \
        how it landed. When in doubt whether a point is substantive, include it. Leave \
        out only filler, small talk, and verbatim repetition.

        Use visual aids where they genuinely clarify: when the discussion describes a \
        process or workflow, a system structure, a decision tree, a sequence of \
        interactions, or a timeline/plan, render it as a Mermaid diagram in a \
        ```mermaid code block (flowchart, sequenceDiagram, timeline, …) alongside the \
        prose; use Markdown tables for comparisons and option matrices. Only diagram \
        what was actually discussed — never decorate for its own sake.

        Rules:
        1. The transcript comes from speech recognition and contains mis-recognized \
        words; silently correct them from context. Never invent content — attendees, \
        decisions, dates — that the transcript does not support.
        2. Output Markdown, and only the document itself — no preamble or commentary.
        """
        let glossary = Settings.shared.glossaryText
        if !glossary.isEmpty {
            prompt += """


            Glossary — terms the speakers actually use. When a word in the transcript \
            sounds like (or is a plausible mis-recognition of) a glossary term, use the \
            exact glossary spelling. Lines of the form "wrong -> right" map a frequent \
            mis-recognition to the preferred term.

            \(glossary)
            """
        }
        return prompt
    }

    /// Refine `text`. On any failure the completion receives the original text so injection
    /// can still proceed.
    static func refine(_ text: String, completion: @escaping (Result<String, Error>) -> Void) {
        let settings = Settings.shared
        request(
            text: text,
            baseURL: settings.llmBaseURL,
            apiKey: settings.llmAPIKey,
            model: settings.llmModel,
            proto: settings.llmProtocol,
            completion: completion
        )
    }

    /// Generate formal meeting minutes from a raw long-form transcript,
    /// using the configured provider and the user's glossary. `meetingDate`
    /// is the recording timestamp shown in the 회의 개요 table.
    static func generateMeetingNotes(from transcript: String, meetingDate: String, completion: @escaping (Result<String, Error>) -> Void) {
        let settings = Settings.shared
        request(
            text: transcript,
            baseURL: settings.llmBaseURL,
            apiKey: settings.llmAPIKey,
            model: settings.llmModel,
            proto: settings.llmProtocol,
            systemPrompt: meetingNotesPrompt(meetingDate: meetingDate),
            reasoningEffort: "medium",
            completion: completion
        )
    }

    /// Used by refinement, meeting notes, and the Settings "Test" button.
    static func request(
        text: String,
        baseURL: String,
        apiKey: String,
        model: String,
        proto: LLMProtocol = .openai,
        systemPrompt: String? = nil,
        reasoningEffort: String = "low",
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let prompt = systemPrompt ?? self.systemPrompt
        switch proto {
        case .openai:
            requestOpenAI(text: text, baseURL: baseURL, apiKey: apiKey, model: model, systemPrompt: prompt, completion: completion)
        case .anthropic:
            requestAnthropic(text: text, baseURL: baseURL, apiKey: apiKey, model: model, systemPrompt: prompt, completion: completion)
        case .chatgpt:
            requestChatGPT(text: text, model: model, systemPrompt: prompt, reasoningEffort: reasoningEffort, completion: completion)
        }
    }

    // MARK: - ChatGPT subscription (Codex backend, OAuth)

    /// Calls the ChatGPT backend Responses endpoint using the subscription OAuth
    /// token. The backend requires the Codex CLI system prompt in `instructions`
    /// and store=false + stream=true; our refinement prompt rides along as a
    /// developer message in `input`.
    private static func requestChatGPT(
        text: String,
        model: String,
        systemPrompt: String,
        reasoningEffort: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        ChatGPTOAuth.shared.withFreshToken { tokenResult in
            switch tokenResult {
            case .failure(let error):
                completion(.failure(error))
            case .success(let token):
                CodexInstructions.fetch(for: model) { instructions in
                    guard let instructions else {
                        completion(.failure(RefineError(message: "Could not load Codex instructions (network required on first use)")))
                        return
                    }
                    sendChatGPT(text: text, model: model, instructions: instructions,
                                systemPrompt: systemPrompt, reasoningEffort: reasoningEffort,
                                access: token.access, accountID: token.accountID,
                                completion: completion)
                }
            }
        }
    }

    private static func sendChatGPT(
        text: String,
        model: String,
        instructions: String,
        systemPrompt: String,
        reasoningEffort: String,
        access: String,
        accountID: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let url = URL(string: "https://chatgpt.com/backend-api/codex/responses")!
        let body: [String: Any] = [
            "model": model,
            "instructions": instructions,
            "input": [
                ["type": "message", "role": "developer",
                 "content": [["type": "input_text", "text": systemPrompt]]],
                ["type": "message", "role": "user",
                 "content": [["type": "input_text", "text": text]]],
            ],
            "store": false,
            "stream": true,
            "include": ["reasoning.encrypted_content"],
            "reasoning": ["effort": reasoningEffort, "summary": "auto"],
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        req.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
        req.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        req.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        req.setValue("text/event-stream", forHTTPHeaderField: "accept")
        req.setValue(UUID().uuidString, forHTTPHeaderField: "session_id")
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion(.failure(RefineError(message: "Failed to build request: \(error.localizedDescription)")))
            return
        }

        send(req, original: text) { data in
            parseSSEOutputText(data)
        } completion: { completion($0) }
    }

    /// Extracts the assistant's final text from a Responses-API SSE stream.
    /// Prefers the terminal response.completed/response.done payload; falls back
    /// to accumulated response.output_text.delta events.
    private static func parseSSEOutputText(_ data: Data) -> String? {
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        var finalText: String?
        var deltas = ""
        for line in raw.split(separator: "\n") {
            guard line.hasPrefix("data: ") else { continue }
            let payload = line.dropFirst(6)
            if payload == "[DONE]" { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            switch type {
            case "response.output_text.delta":
                if let d = obj["delta"] as? String { deltas += d }
            case "response.completed", "response.done":
                guard let resp = obj["response"] as? [String: Any],
                      let output = resp["output"] as? [[String: Any]] else { continue }
                var texts: [String] = []
                for item in output where (item["type"] as? String) == "message" {
                    for part in (item["content"] as? [[String: Any]] ?? [])
                    where (part["type"] as? String) == "output_text" {
                        if let t = part["text"] as? String { texts.append(t) }
                    }
                }
                if !texts.isEmpty { finalText = texts.joined() }
            default:
                break
            }
        }
        return finalText ?? (deltas.isEmpty ? nil : deltas)
    }

    // MARK: - OpenAI-compatible

    private static func requestOpenAI(
        text: String,
        baseURL: String,
        apiKey: String,
        model: String,
        systemPrompt: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let url = endpoint(from: baseURL, suffix: "chat/completions") else {
            completion(.failure(RefineError(message: "Invalid API Base URL")))
            return
        }

        let body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text]
            ]
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion(.failure(RefineError(message: "Failed to build request: \(error.localizedDescription)")))
            return
        }

        send(req, original: text) { data in
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                return nil
            }
            return content
        } completion: { completion($0) }
    }

    // MARK: - Anthropic Messages

    private static func requestAnthropic(
        text: String,
        baseURL: String,
        apiKey: String,
        model: String,
        systemPrompt: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let url = endpoint(from: baseURL, suffix: "messages") else {
            completion(.failure(RefineError(message: "Invalid API Base URL")))
            return
        }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16384,
            "temperature": 0,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": text]
            ]
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion(.failure(RefineError(message: "Failed to build request: \(error.localizedDescription)")))
            return
        }

        send(req, original: text) { data in
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = json["content"] as? [[String: Any]],
                  let first = content.first,
                  let textValue = first["text"] as? String else {
                return nil
            }
            return textValue
        } completion: { completion($0) }
    }

    // MARK: - Shared transport

    /// Sends a prepared request, validates the HTTP status, and extracts the assistant
    /// text via `parse`. Falls back to the original text when the model returns empty.
    private static func send(
        _ req: URLRequest,
        original: String,
        parse: @escaping (Data) -> String?,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let task = URLSession.shared.dataTask(with: req) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(RefineError(message: "No response")))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                let detail = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                completion(.failure(RefineError(message: "HTTP \(http.statusCode): \(detail)")))
                return
            }
            guard let data, let content = parse(data) else {
                completion(.failure(RefineError(message: "Unexpected response format")))
                return
            }
            let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
            completion(.success(cleaned.isEmpty ? original : cleaned))
        }
        task.resume()
    }

    /// Build the endpoint URL, tolerating base URLs with or without the full path.
    /// Rejects non-HTTPS schemes (except for localhost) so the API key and
    /// transcript are never sent over plaintext.
    private static func endpoint(from base: String, suffix: String) -> URL? {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }

        let candidateString: String
        if trimmed.hasSuffix("/" + suffix) {
            candidateString = trimmed
        } else {
            candidateString = trimmed + "/" + suffix
        }
        guard let url = URL(string: candidateString) else { return nil }
        switch url.scheme?.lowercased() {
        case "https":
            return url
        case "http":
            let host = url.host?.lowercased() ?? ""
            return (host == "localhost" || host == "127.0.0.1") ? url : nil
        default:
            return nil
        }
    }
}
