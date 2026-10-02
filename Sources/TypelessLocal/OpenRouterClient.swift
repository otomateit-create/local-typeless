import Foundation

enum OpenRouterError: Error, LocalizedError {
    case missingAPIKey
    case http(status: Int, body: String)
    case emptyResponse
    case rejected
    case allModelsFailed([String])

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Clé API OpenRouter introuvable dans le Trousseau."
        case .http(let status, let body):
            return "HTTP \(status) \(body)"
        case .emptyResponse:
            return "réponse vide"
        case .rejected:
            return "sortie refusée (ce n'est plus la dictée)"
        case .allModelsFailed(let details):
            return "tous les modèles ont échoué — \(details.joined(separator: " | "))"
        }
    }
}

struct OpenRouterClient {
    /// Modèles retenus après test comparatif sur le prompt réel (fidélité,
    /// mise en forme, résistance à l'injection, latence).
    ///
    /// L'ordre est délibéré : Gemini Flash-Lite est le plus rapide et le seul
    /// sans défaut ; Nova Lite le suit car il est d'un *autre fournisseur*, ce
    /// qui protège d'une panne côté Google ; Gemma ferme la marche.
    ///
    /// Écartés : claude-haiku-4.5 (supprime du contenu), mistral-nemo (répond
    /// aux questions dictées), qwen3.7-flash et deepseek-v4-flash (trop lents).
    static let models = [
        "google/gemini-2.5-flash-lite",
        "amazon/nova-lite-v1",
        "google/gemma-3-12b-it"
    ]

    /// Une seconde passe après une courte pause rattrape les refus temporaires.
    private let passes = 2
    private let delayBetweenPasses: Duration = .milliseconds(800)

    private let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    func cleanup(transcript: String) async throws -> String {
        guard let apiKey = KeychainStore.readAPIKey() else {
            throw OpenRouterError.missingAPIKey
        }

        var failures: [String] = []

        for pass in 0..<passes {
            if pass > 0 {
                print("⏳ Tous les modèles saturés, nouvelle tentative…")
                try? await Task.sleep(for: delayBetweenPasses)
            }

            for model in Self.models {
                do {
                    let cleaned = try await send(transcript: transcript, model: model, apiKey: apiKey)
                    if model != Self.models.first || pass > 0 {
                        print("ℹ️ Modèle utilisé : \(model)")
                    }
                    return cleaned
                } catch {
                    let short = model.replacingOccurrences(of: ":free", with: "")
                    failures.append("\(short): \(error.localizedDescription.prefix(80))")
                }
            }
        }

        throw OpenRouterError.allModelsFailed(failures)
    }

    private func send(transcript: String, model: String, apiKey: String) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            // `exclude` sans `enabled: false` : certains endpoints imposent le
            // raisonnement et rejettent toute tentative de le désactiver. On se
            // contente donc de ne pas le recevoir, ce qui garde la sortie propre.
            "reasoning": ["exclude": true],
            "messages": [
                ["role": "system", "content": CleanupPrompt.system],
                ["role": "user", "content": CleanupPrompt.user(transcript: transcript)]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw OpenRouterError.emptyResponse
        }
        guard http.statusCode == 200 else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw OpenRouterError.http(status: http.statusCode, body: Self.summarize(raw))
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw OpenRouterError.emptyResponse
        }

        let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw OpenRouterError.emptyResponse }

        // Le modèle a désormais le droit de réécrire la forme et de structurer :
        // on vérifie qu'il n'en a pas profité pour répondre, résumer ou inventer.
        guard let accepted = CleanupGuard.accept(cleaned, for: transcript) else {
            throw OpenRouterError.rejected
        }
        return accepted
    }

    /// Extrait le message d'erreur du JSON d'OpenRouter pour garder des logs lisibles.
    private static func summarize(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return String(raw.prefix(80))
        }
        return message
    }
}
