import Foundation

/// Wire protocol used to talk to a provider's chat endpoint.
enum LLMProtocol {
    case openai      // POST {base}/chat/completions, Authorization: Bearer
    case anthropic   // POST {base}/messages, x-api-key + anthropic-version
    case chatgpt     // POST chatgpt.com/backend-api/codex/responses, OAuth (ChatGPT subscription)
}

/// A curated LLM provider with its endpoint and a short list of recent models.
/// Model lists are sourced from the opencode / models.dev registry and limited to
/// recent text-capable models. The `.custom` provider lets the user enter any
/// OpenAI-compatible endpoint and model manually.
struct LLMProvider {
    let id: String
    let displayName: String
    let baseURL: String
    let proto: LLMProtocol
    let models: [String]
    let defaultModel: String
    /// Valid `reasoning_effort` values for this provider (OpenAI-style). Empty
    /// means the provider has no reasoning-effort control.
    let reasoningEfforts: [String]
    var isCustom: Bool { id == "custom" }

    static let custom = LLMProvider(
        id: "custom",
        displayName: "Custom (OpenAI-compatible)",
        baseURL: "",
        proto: .openai,
        models: [],
        defaultModel: "",
        reasoningEfforts: ["minimal", "low", "medium", "high"]
    )

    /// All selectable providers, in menu order. `custom` is last.
    static let all: [LLMProvider] = [
        LLMProvider(
            id: "chatgpt", displayName: "ChatGPT (Plus/Pro Subscription)",
            baseURL: "https://chatgpt.com/backend-api", proto: .chatgpt,
            // Must match the backend's model catalog (GET /codex/models); older
            // gpt-5.1/5.2 slugs are rejected with HTTP 400 as of mid-2026.
            models: ["gpt-5.4-mini", "gpt-5.5", "gpt-5.4"],
            defaultModel: "gpt-5.4-mini",
            reasoningEfforts: ["low", "medium", "high"]
        ),
        LLMProvider(
            id: "openai", displayName: "OpenAI",
            baseURL: "https://api.openai.com/v1", proto: .openai,
            models: ["gpt-5.5", "gpt-5.5-pro", "gpt-5.4", "gpt-5.4-mini", "gpt-5.4-nano", "gpt-5.4-pro"],
            defaultModel: "gpt-5.4-mini",
            reasoningEfforts: ["minimal", "low", "medium", "high"]
        ),
        LLMProvider(
            id: "anthropic", displayName: "Anthropic",
            baseURL: "https://api.anthropic.com/v1", proto: .anthropic,
            models: ["claude-opus-4-8", "claude-opus-4-7", "claude-sonnet-4-6", "claude-opus-4-6", "claude-opus-4-5", "claude-haiku-4-5"],
            defaultModel: "claude-sonnet-4-6",
            reasoningEfforts: []
        ),
        LLMProvider(
            id: "google", displayName: "Google (Gemini)",
            baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", proto: .openai,
            models: ["gemini-3.5-flash", "gemini-3.1-flash-lite", "gemini-3.1-pro-preview"],
            defaultModel: "gemini-3.5-flash",
            reasoningEfforts: ["low", "medium", "high"]
        ),
        LLMProvider(
            id: "xai", displayName: "xAI (Grok)",
            baseURL: "https://api.x.ai/v1", proto: .openai,
            models: ["grok-4.3", "grok-4.20-0309-reasoning", "grok-4.20-0309-non-reasoning"],
            defaultModel: "grok-4.3",
            reasoningEfforts: ["low", "high"]
        ),
        LLMProvider(
            id: "deepseek", displayName: "DeepSeek",
            baseURL: "https://api.deepseek.com/v1", proto: .openai,
            models: ["deepseek-v4-pro", "deepseek-v4-flash", "deepseek-chat", "deepseek-reasoner"],
            defaultModel: "deepseek-chat",
            reasoningEfforts: []
        ),
        LLMProvider(
            id: "xiaomi-mimo", displayName: "Xiaomi MiMo",
            baseURL: "https://api.xiaomimimo.com/v1", proto: .openai,
            models: ["mimo-v2.5-pro", "mimo-v2.5", "mimo-v2.5-pro-ultraspeed", "mimo-v2-flash"],
            defaultModel: "mimo-v2.5",
            reasoningEfforts: []
        ),
        LLMProvider(
            id: "zai", displayName: "Z.AI (GLM)",
            baseURL: "https://api.z.ai/api/paas/v4", proto: .openai,
            models: ["glm-5.2", "glm-5.1", "glm-5", "glm-5-turbo", "glm-4.7-flash"],
            defaultModel: "glm-5",
            reasoningEfforts: []
        ),
        LLMProvider(
            id: "kimi", displayName: "Kimi (Moonshot)",
            baseURL: "https://api.moonshot.ai/v1", proto: .openai,
            models: ["kimi-k2.7-code", "kimi-k2.6", "kimi-k2.5", "kimi-k2-thinking"],
            defaultModel: "kimi-k2.6",
            reasoningEfforts: []
        ),
        LLMProvider(
            id: "minimax", displayName: "MiniMax",
            baseURL: "https://api.minimax.io/anthropic/v1", proto: .anthropic,
            models: ["MiniMax-M3", "MiniMax-M2.7", "MiniMax-M2.5"],
            defaultModel: "MiniMax-M2.7",
            reasoningEfforts: []
        ),
        LLMProvider(
            id: "alibaba", displayName: "Alibaba (Qwen)",
            baseURL: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1", proto: .openai,
            models: ["qwen3.7-plus", "qwen3.7-max", "qwen3.6-flash", "qwen3.6-plus"],
            defaultModel: "qwen3.6-flash",
            reasoningEfforts: []
        ),
        custom,
    ]

    static func provider(id: String) -> LLMProvider {
        all.first { $0.id == id } ?? custom
    }
}
