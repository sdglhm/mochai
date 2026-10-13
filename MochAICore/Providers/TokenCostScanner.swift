import Foundation

struct ModelRate: Equatable, Sendable {
    var input: Double
    var output: Double
    var cacheRead: Double?
    var cacheWrite: Double?
}

/// USD per million tokens, keyed by provider id then model id.
struct TokenCostCatalog: Equatable, Sendable {
    var providers: [String: [String: ModelRate]]

    func rate(for model: String, provider: ProviderID) -> ModelRate? {
        let names = Self.candidates(model)
        let preferred = provider == .codex ? "openai" : "anthropic"
        if let table = providers[preferred] {
            for name in names {
                if let rate = table[name] { return rate }
            }
        }
        var matches: [ModelRate] = []
        for name in names {
            for (id, table) in providers where id != preferred {
                if let rate = table[name] { matches.append(rate) }
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    static func candidates(_ model: String) -> [String] {
        var name = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["anthropic/", "openai/", "claude/", "models/"] where name.hasPrefix(prefix) {
            name.removeFirst(prefix.count)
        }
        var names = [name]
        if name.hasSuffix("-latest") {
            names.append(String(name.dropLast("-latest".count)))
        }
        if let range = name.range(of: #"-(\d{8})$"#, options: .regularExpression) {
            names.append(String(name[..<range.lowerBound]))
        }
        return names
    }

    static func parse(_ data: Data) -> TokenCostCatalog {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return TokenCostCatalog(providers: [:])
        }
        var providers: [String: [String: ModelRate]] = [:]
        for (providerID, value) in object {
            guard let provider = value as? [String: Any],
                  let models = provider["models"] as? [String: Any] else { continue }
            var table: [String: ModelRate] = [:]
            for (modelID, modelValue) in models {
                guard let model = modelValue as? [String: Any],
                      let cost = model["cost"] as? [String: Any],
                      let input = number(cost["input"]),
                      let output = number(cost["output"]) else { continue }
                table[modelID.lowercased()] = ModelRate(
                    input: input,
                    output: output,
                    cacheRead: number(cost["cache_read"]),
                    cacheWrite: number(cost["cache_write"])
                )
            }
            if !table.isEmpty { providers[providerID.lowercased()] = table }
        }
        return TokenCostCatalog(providers: providers)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let raw = number.doubleValue
        return raw.isFinite && raw >= 0 ? raw : nil
    }
}

enum TokenCostCatalogStore {
    static func load(cacheURL: URL = AppPaths.supportDirectory.appendingPathComponent("model-pricing.json")) async -> TokenCostCatalog {
        let fresh = cached(cacheURL, maxAge: 24 * 3600)
        if let fresh { return fresh }
        if let data = try? await fetch(), let catalog = store(data, cacheURL: cacheURL) {
            return catalog
        }
        return cached(cacheURL, maxAge: .greatestFiniteMagnitude) ?? TokenCostCatalog(providers: [:])
    }

    private static func fetch() async throws -> Data {
        var request = URLRequest(url: URL(string: "https://models.dev/api.json")!)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 20_000_000 else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private static func store(_ data: Data, cacheURL: URL) -> TokenCostCatalog? {
        let catalog = TokenCostCatalog.parse(data)
        guard !catalog.providers.isEmpty else { return nil }
        var slim: [String: [String: [String: Double]]] = [:]
        for (provider, models) in catalog.providers {
            var table: [String: [String: Double]] = [:]
            for (model, rate) in models {
                var cost = ["input": rate.input, "output": rate.output]
                if let cacheRead = rate.cacheRead { cost["cache_read"] = cacheRead }
                if let cacheWrite = rate.cacheWrite { cost["cache_write"] = cacheWrite }
                table[model] = cost
            }
            slim[provider] = table
        }
        // The slim cache is rewritten through the same parser, so it needs a models wrapper.
        var wrapped: [String: [String: Any]] = [:]
        for (provider, models) in slim {
            var modelsObject: [String: Any] = [:]
            for (model, cost) in models { modelsObject[model] = ["cost": cost] }
            wrapped[provider] = ["models": modelsObject]
        }
        if let encoded = try? JSONSerialization.data(withJSONObject: wrapped) {
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? encoded.write(to: cacheURL, options: .atomic)
        }
        return catalog
    }

    private static func cached(_ url: URL, maxAge: TimeInterval) -> TokenCostCatalog? {
        guard let data = try? Data(contentsOf: url),
              let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              Date().timeIntervalSince(date) <= maxAge else { return nil }
        let catalog = TokenCostCatalog.parse(data)
        return catalog.providers.isEmpty ? nil : catalog
    }
}

enum TokenCostScanner {
    /// Prices token counts already recorded on this Mac. Prompt text is not kept.
    static func monthToDate(
        provider: ProviderID,
        directory: URL,
        catalog: TokenCostCatalog,
        now: Date = Date()
    ) -> TokenCost? {
        let start = Calendar.current.dateInterval(of: .month, for: now)?.start ?? now
        let files = sessionFiles(in: directory, modifiedAfter: start)
        guard !files.isEmpty else { return nil }
        var usd = 0.0
        var priced = 0
        var unpriced = 0
        for url in files {
            var carriedModel = ""
            scan(url) { line in
                if let hint = UsageTokenRecord.modelHint(line) {
                    carriedModel = hint
                }
                guard var record = UsageTokenRecord.parse(line, provider: provider) else { return }
                if record.model.isEmpty {
                    record.model = carriedModel
                } else {
                    carriedModel = record.model
                }
                guard record.date >= start, record.date <= now else { return }
                guard record.tokens.count > 0 else { return }
                guard !record.model.isEmpty, let rate = catalog.rate(for: record.model, provider: provider) else {
                    unpriced += record.tokens.count
                    return
                }
                usd += price(record.tokens, rate: rate, provider: provider)
                priced += record.tokens.count
            }
        }
        guard priced > 0 || unpriced == 0 else { return nil }
        return TokenCost(usd: usd, period: "This month", estimated: true)
    }

    static func price(_ tokens: TokenCounts, rate: ModelRate, provider: ProviderID) -> Double {
        let cacheReadRate = rate.cacheRead ?? rate.input
        let cacheWriteRate = rate.cacheWrite ?? rate.input
        let freshInput: Int
        if provider == .codex {
            freshInput = max(0, tokens.input - tokens.cacheRead - tokens.cacheWrite)
        } else {
            freshInput = tokens.input
        }
        let million = 1_000_000.0
        return Double(freshInput) * rate.input / million
            + Double(tokens.output) * rate.output / million
            + Double(tokens.cacheRead) * cacheReadRate / million
            + Double(tokens.cacheWrite) * cacheWriteRate / million
    }

    private static func sessionFiles(in directory: URL, modifiedAfter start: Date) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let modified = values?.contentModificationDate, modified >= start else { continue }
            files.append(url)
            if files.count >= 400 { break }
        }
        return files
    }

    private static func scan(_ url: URL, _ visit: (String) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let chunk = 256 * 1024
        var pending = Data()
        var scanned = 0
        let limit = 64 * 1024 * 1024
        while scanned < limit, let piece = try? handle.read(upToCount: chunk), !piece.isEmpty {
            scanned += piece.count
            pending.append(piece)
            while let newline = pending.firstIndex(of: 10) {
                let line = pending[..<newline]
                pending.removeSubrange(...newline)
                guard line.count <= 4_000_000, let text = String(data: line, encoding: .utf8) else { continue }
                if text.contains("\"usage\"") || text.contains("token_count") || text.contains("last_token_usage") || text.contains("\"model\"") {
                    visit(text)
                }
            }
        }
        if !pending.isEmpty, pending.count <= 4_000_000, let text = String(data: pending, encoding: .utf8),
           text.contains("\"usage\"") || text.contains("token_count") || text.contains("last_token_usage") || text.contains("\"model\"") {
            visit(text)
        }
    }
}

struct TokenCounts: Equatable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    var count: Int { input + output + cacheRead + cacheWrite }
}

struct UsageTokenRecord: Equatable {
    var model: String
    var date: Date
    var tokens: TokenCounts

    static func parse(_ line: String, provider: ProviderID) -> UsageTokenRecord? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let usage = usageDictionary(in: object, provider: provider)
        guard let usage else { return nil }
        let tokens = counts(in: usage)
        guard tokens.count > 0, let date = timestamp(in: object) else { return nil }
        return UsageTokenRecord(model: modelName(in: object) ?? "", date: date, tokens: tokens)
    }

    private static func usageDictionary(in object: [String: Any], provider: ProviderID) -> [String: Any]? {
        if provider == .codex {
            let info = (object["payload"] as? [String: Any])?["info"] as? [String: Any]
            if let last = info?["last_token_usage"] as? [String: Any] { return last }
            if let last = object["last_token_usage"] as? [String: Any] { return last }
        }
        if let message = object["message"] as? [String: Any], let usage = message["usage"] as? [String: Any] {
            return usage
        }
        return object["usage"] as? [String: Any]
    }

    private static func counts(in usage: [String: Any]) -> TokenCounts {
        TokenCounts(
            input: integer(usage["input_tokens"]),
            output: integer(usage["output_tokens"]),
            cacheRead: integer(usage["cache_read_input_tokens"] ?? usage["cached_input_tokens"]),
            cacheWrite: integer(usage["cache_creation_input_tokens"] ?? usage["cache_write_input_tokens"])
        )
    }

    static func modelHint(_ line: String) -> String? {
        guard line.contains("\"model\""),
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let payload = object["payload"] as? [String: Any]
        let state = payload?["state"] as? [String: Any]
        for value in [payload?["model"], state?["model"], modelName(in: object)] {
            if let text = value as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, trimmed.count <= 80 { return trimmed }
            }
        }
        return nil
    }

    private static func modelName(in object: [String: Any]) -> String? {
        let message = object["message"] as? [String: Any]
        let payload = object["payload"] as? [String: Any]
        let info = payload?["info"] as? [String: Any]
        for value in [message?["model"], info?["model"], payload?["model"], object["model"]] {
            if let text = value as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func timestamp(in object: [String: Any]) -> Date? {
        for key in ["timestamp", "created_at", "createdAt"] {
            if let date = date(object[key]) { return date }
        }
        return nil
    }

    private static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber, number.doubleValue > 1_000_000_000 {
            let raw = number.doubleValue
            return Date(timeIntervalSince1970: raw > 1_000_000_000_000 ? raw / 1000 : raw)
        }
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private static func integer(_ value: Any?) -> Int {
        guard let number = value as? NSNumber else { return 0 }
        let raw = number.intValue
        return raw > 0 ? raw : 0
    }
}
