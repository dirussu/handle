import Foundation

/// Token → dollar estimates for the models Handle bundles in its pickers
/// (PROVIDERS.md: show the cost; tokens-only when the price is unknown).
/// List prices per million tokens; cache reads at 10 % and cache writes at
/// 125 % of the input price, Anthropic's standard prompt-caching rates.
/// Verify against the provider's pricing page when models change.
nonisolated enum AICost {
    struct Price: Sendable { let input: Double; let output: Double }

    static let perMillion: [String: Price] = [
        "claude-sonnet-5": Price(input: 2.00, output: 10.00),
        "claude-opus-5": Price(input: 5.00, output: 25.00),
        "claude-haiku-4-5": Price(input: 1.00, output: 5.00),
    ]

    /// Dollars, or nil when the model has no price on file.
    static func estimate(model: String?, input: Int, output: Int, cacheRead: Int = 0, cacheWrite: Int = 0) -> Double? {
        guard let model, let p = perMillion[model] else { return nil }
        let m = 1_000_000.0
        return Double(input) / m * p.input
             + Double(output) / m * p.output
             + Double(cacheRead) / m * p.input * 0.10
             + Double(cacheWrite) / m * p.input * 1.25
    }

    static func format(_ dollars: Double) -> String {
        if dollars < 0.01 { return String(format: "$%.4f", dollars) }
        return String(format: "$%.2f", dollars)
    }

    static func formatTokens(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
