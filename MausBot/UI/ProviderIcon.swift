import SwiftUI
import AppKit

struct ProviderIcon: View {
    let selection: ModelSelection?
    let instances: [ProviderInstance]

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "cpu")
                .appFont(size: 10, weight: .medium)
                .accessibilityHidden(true)
        }
    }

    private var image: NSImage? {
        guard let name = Self.iconName(selection: selection, instances: instances),
              let image = NSImage(named: "Provider-\(name)")?.copy() as? NSImage else { return nil }
        image.size = NSSize(width: 10, height: 10)
        return image
    }

    static func iconName(selection: ModelSelection?, instances: [ProviderInstance]) -> String? {
        guard let selection else { return nil }
        let instance = instances.first { $0.instanceId == selection.instanceId }
        let model = instance?.models.first { $0.id == selection.model }
        for value in [model?.provider, selection.model, model?.label, instance?.driverKind, instance?.instanceId, instance?.displayName] {
            if let value, let name = iconName(for: value) { return name }
        }
        return nil
    }

    private static func iconName(for value: String) -> String? {
        let value = value.lowercased()
        let words = value.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let aliases: [(String, [String])] = [
            ("openai", ["openai", "chatgpt", "gpt", "codex", "o1", "o3", "o4"]),
            ("claude", ["anthropic", "claude"]),
            ("gemini", ["google", "gemini"]),
            ("deepseek", ["deepseek"]),
            ("qwen", ["qwen", "alibaba", "dashscope"]),
            ("xai", ["xai", "grok"]),
            ("meta", ["meta", "llama"]),
            ("mistral", ["mistral", "codestral", "mixtral"]),
            ("moonshot", ["moonshot", "kimi"]),
            ("zhipu", ["zhipu", "zhipuai", "glm"]),
            ("bytedance", ["bytedance", "doubao", "volcengine"]),
            ("minimax", ["minimax"]),
            ("perplexity", ["perplexity", "sonar"]),
            ("openrouter", ["openrouter"]),
            ("ollama", ["ollama"])
        ]
        return aliases.first { _, names in
            names.contains { name in
                words.contains { word in
                    word == name || (word.hasPrefix(name) && word.dropFirst(name.count).first?.isNumber == true)
                }
            }
        }?.0
    }
}
