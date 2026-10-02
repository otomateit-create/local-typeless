import Foundation

/// Filet de sécurité sur la sortie du LLM.
///
/// Le prompt autorise désormais le modèle à réécrire la forme et à structurer le
/// texte. C'est précisément ce qui, d'après le benchmark DRES, pousse les modèles
/// à sur-supprimer ou à paraphraser. On *accepte* donc la réponse sans lui faire
/// confiance : ce qui n'est plus reconnaissable comme une mise au propre de la
/// dictée est refusé, et l'appelant se rabat sur le modèle suivant puis, en
/// dernier recours, sur la transcription brute.
///
/// Approche reprise de `DictationPolisher.accept` (BasedHardware/omi), avec des
/// seuils élargis : la dictée française observée ici est plus disfluente que les
/// exemples anglais d'origine, donc le nettoyage raccourcit davantage.
enum CleanupGuard {
    /// Rapport de longueur admissible entre la sortie et l'entrée. Le nettoyage
    /// raccourcit (faux départs, tics) mais ne résume pas.
    private static let acceptableWordRatio: ClosedRange<Double> = 0.4...1.6

    /// Part minimale des mots de la sortie devant déjà figurer dans l'entrée.
    /// Une mise au propre garde les mots du locuteur ; une réponse, un résumé ou
    /// une hallucination est majoritairement composé de mots nouveaux.
    private static let minimumSharedWordFraction = 0.6

    /// En dessous de ce nombre de mots, les ratios ne veulent plus rien dire :
    /// seule la détection de préambule s'applique.
    private static let minimumWordsForRatios = 12

    /// Le modèle qui répond, s'excuse ou annonce son travail au lieu de nettoyer.
    /// Refusé seulement si la dictée elle-même ne commençait pas ainsi — « je suis
    /// désolé de ne pas avoir répondu » est une dictée parfaitement légitime.
    private static let refusalOpenings = [
        "je suis désolé", "désolé,", "je ne peux pas", "en tant qu'ia", "en tant que modèle",
        "bien sûr,", "bien sûr !", "voici le texte", "voici la transcription", "d'accord, voici",
        "transcription nettoyée", "texte nettoyé",
        "i'm sorry", "i am sorry", "i cannot", "i can't", "as an ai", "sure,", "here is", "here's",
    ]

    /// Balises de raisonnement que certains modèles émettent malgré
    /// `reasoning: {exclude: true}`.
    private static let reasoningPatterns = [
        #"(?s)<thinking>.*?</thinking>"#,
        #"(?s)<think>.*?</think>"#,
        #"(?s)<reasoning>.*?</reasoning>"#,
    ]

    /// La sortie du modèle si elle est reconnaissable comme un nettoyage de
    /// `original` ; `nil` quand l'appelant doit la rejeter.
    static func accept(_ candidate: String, for original: String) -> String? {
        var text = stripReasoning(candidate).trimmingCharacters(in: .whitespacesAndNewlines)
        let source = original.trimmingCharacters(in: .whitespacesAndNewlines)

        text = unwrapQuotes(text, source: source)
        guard !text.isEmpty else { return nil }

        // Une note *à propos* du texte plutôt que le texte : « (aucun texte
        // fourni) », « [inaudible] ».
        if let open = text.first, let close = text.last,
           [("(", ")"), ("[", "]"), ("{", "}")].contains(where: { $0.0 == open && $0.1 == close }),
           source.first != open {
            return nil
        }

        let loweredCandidate = text.lowercased()
        let loweredSource = source.lowercased()
        for opening in refusalOpenings
        where loweredCandidate.hasPrefix(opening) && !loweredSource.hasPrefix(opening) {
            return nil
        }

        let sourceWords = words(in: source)
        guard sourceWords.count >= minimumWordsForRatios else { return text }

        let candidateWords = words(in: text)
        guard !candidateWords.isEmpty else { return nil }

        let ratio = Double(candidateWords.count) / Double(sourceWords.count)
        guard acceptableWordRatio.contains(ratio) else { return nil }

        // Les mots contenant un chiffre ou « @ » sont exclus : nombres, heures et
        // adresses sont justement ceux que le modèle a pour consigne de réécrire
        // (« quatorze heures » → « 14h »).
        let sourceSet = Set(sourceWords)
        let comparable = candidateWords.filter { !$0.contains(where: \.isNumber) && !$0.contains("@") }
        guard !comparable.isEmpty else { return text }

        let shared = comparable.filter(sourceSet.contains).count
        let fraction = Double(shared) / Double(comparable.count)
        guard fraction >= minimumSharedWordFraction else { return nil }

        return text
    }

    private static func stripReasoning(_ text: String) -> String {
        var result = text
        for pattern in reasoningPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }
        return result
    }

    /// Retire les guillemets dont le modèle a entouré sa réponse, sauf si la
    /// dictée s'ouvrait elle-même sur un guillemet.
    private static func unwrapQuotes(_ text: String, source: String) -> String {
        let pairs: [(Character, Character)] = [("\"", "\""), ("«", "»"), ("“", "”"), ("'", "'")]
        for (open, close) in pairs
        where text.count >= 2 && text.first == open && text.last == close && source.first != open {
            return String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// Mots normalisés (sans casse ni accents) pour la comparaison : « Ça » et
    /// « ça » ne doivent pas compter comme deux mots différents.
    private static func words(in text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
