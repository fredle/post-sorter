import Foundation

/// The fields read out of a letter, by Apple Intelligence or by `PatternExtractor`.
struct ExtractedFields: Equatable {
    var sender = ""
    var kind: LetterKind = .other
    var summary = ""
    var action = ""
    var dueDate: Date?
    var amount: Double?
    var currency: String?
    var reference = ""
    var needsAction = false

    /// Keeps these values and fills any blanks from `fallback`.
    func filling(from fallback: ExtractedFields) -> ExtractedFields {
        var result = self
        if result.sender.isEmpty { result.sender = fallback.sender }
        if result.summary.isEmpty { result.summary = fallback.summary }
        if result.kind == .other { result.kind = fallback.kind }
        if result.needsAction && result.action.isEmpty { result.action = fallback.action }
        if result.needsAction && result.dueDate == nil { result.dueDate = fallback.dueDate }
        if result.amount == nil {
            result.amount = fallback.amount
            if result.currency == nil { result.currency = fallback.currency }
        }
        if result.currency == nil { result.currency = fallback.currency }
        if result.reference.isEmpty { result.reference = fallback.reference }
        return result
    }
}

/// Reads a letter with data detectors and regular expressions. Works on every
/// iPhone, with or without Apple Intelligence.
enum PatternExtractor {
    static func extract(from text: String, now: Date = Date(), calendar: Calendar = .current) -> ExtractedFields {
        var fields = ExtractedFields()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fields }
        fields.kind = classify(text)
        fields.sender = sender(in: text)
        fields.dueDate = dueDate(in: text, now: now, calendar: calendar)
        if let money = amount(in: text) {
            fields.amount = money.value
            fields.currency = money.currency
        }
        fields.reference = reference(in: text) ?? ""
        fields.needsAction = fields.dueDate != nil || fields.kind.usuallyNeedsAction
        if fields.needsAction {
            fields.action = fields.kind.suggestedAction(amount: fields.amount, currency: fields.currency ?? MoneyFormat.defaultCurrency)
        }
        fields.summary = summary(kind: fields.kind, sender: fields.sender, amount: fields.amount, currency: fields.currency)
        return fields
    }

    static func summary(kind: LetterKind, sender: String, amount: Double?, currency: String?) -> String {
        var text = sender.isEmpty ? kind.summaryNoun : "\(kind.summaryNoun) from \(sender)"
        if let amount, amount > 0 {
            text += " for " + MoneyFormat.string(amount, currency: currency ?? MoneyFormat.defaultCurrency)
        }
        return text
    }

    // MARK: - Words

    /// Number of whole-word, case-insensitive occurrences of `word` in `text`.
    static func occurrences(of word: String, in text: String) -> Int {
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return 0 }
        return regex.numberOfMatches(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length))
    }

    // MARK: - Type

    private static let kindRules: [(LetterKind, [(String, Int)])] = [
        (.fine, [("penalty charge", 5), ("pcn", 4), ("parking", 3), ("fixed penalty", 5), ("fine", 2), ("contravention", 4), ("speeding", 4)]),
        (.tax, [("council tax", 5), ("hmrc", 5), ("tax return", 4), ("self assessment", 4), ("tax code", 3), ("vehicle tax", 4), ("income tax", 4)]),
        (.appointment, [("appointment", 4), ("clinic", 2), ("please arrive", 3), ("attend", 2), ("outpatient", 3)]),
        (.medical, [("nhs", 2), ("gp", 1), ("surgery", 2), ("prescription", 3), ("hospital", 2), ("test results", 3), ("vaccination", 3), ("screening", 3)]),
        (.renewal, [("renewal", 4), ("renew", 3), ("auto-renew", 4), ("your policy", 2), ("premium", 2), ("tv licence", 4), ("expires", 2), ("expiry", 2)]),
        (.school, [("school", 3), ("pupil", 3), ("parent", 2), ("carer", 1), ("term", 1), ("headteacher", 4), ("trip", 1), ("consent form", 3)]),
        (.bank, [("bank", 2), ("sort code", 3), ("statement", 2), ("overdraft", 3), ("credit card", 2), ("interest rate", 2), ("savings", 2), ("mortgage", 2)]),
        (.bill, [("bill", 3), ("invoice", 3), ("amount due", 4), ("balance", 2), ("direct debit", 2), ("payment", 1), ("pay", 1), ("your account", 1), ("meter reading", 3), ("tariff", 2)]),
    ]

    static func classify(_ text: String) -> LetterKind {
        var bestKind = LetterKind.other
        var bestScore = 0
        for (kind, words) in kindRules {
            var score = 0
            for (word, weight) in words {
                score += min(occurrences(of: word, in: text), 3) * weight
            }
            if score > bestScore {
                bestScore = score
                bestKind = kind
            }
        }
        return bestScore >= 3 ? bestKind : .other
    }

    // MARK: - Sender

    private static let organisationWords = [
        "ltd", "limited", "plc", "llp", "inc", "council", "nhs", "hmrc", "dvla", "bank", "building society",
        "insurance", "energy", "water", "gas", "electricity", "trust", "school", "academy", "university",
        "hospital", "surgery", "police", "borough", "agency", "services", "telecom", "mobile", "broadband", "group",
    ]
    private static let personalPrefixes = ["mr ", "mrs ", "ms ", "miss ", "mx ", "dr ", "the occupier", "dear ", "to "]

    static func sender(in text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let top = Array(lines.prefix(15))

        for line in top where line.count <= 60 {
            let lower = line.lowercased()
            if personalPrefixes.contains(where: { lower.hasPrefix($0) }) { continue }
            if lower.contains("@") || lower.contains("www") || lower.contains("http") { continue }
            if organisationWords.contains(where: { occurrences(of: $0, in: lower) > 0 }) {
                return tidy(line)
            }
        }

        for line in top.prefix(6) {
            guard line.count >= 3, line.count <= 40 else { continue }
            let lower = line.lowercased()
            if personalPrefixes.contains(where: { lower.hasPrefix($0) }) { continue }
            guard line.rangeOfCharacter(from: .decimalDigits) == nil else { continue }
            let letters = line.filter { $0.isLetter }.count
            guard Double(letters) / Double(line.count) >= 0.75 else { continue }
            return tidy(line)
        }
        return ""
    }

    private static func tidy(_ line: String) -> String {
        line.trimmingCharacters(in: CharacterSet(charactersIn: " :,-–|").union(.whitespacesAndNewlines))
    }

    // MARK: - Due date

    private static let dueWords: [(String, Int)] = [
        ("pay by", 6), ("on or before", 6), ("no later than", 6), ("reply by", 6), ("return by", 6),
        ("due date", 5), ("payment date", 5), ("deadline", 5), ("renewal date", 5), ("renews on", 5),
        ("due", 4), ("expires", 4), ("expiry", 4), ("will renew", 4), ("appointment", 4),
        ("before", 3), ("attend", 3), ("collected on", 3), ("will be taken", 3),
        ("by", 2), ("must", 2), ("within", 1),
    ]
    private static let notDueWords: [(String, Int)] = [
        ("date of birth", 8), ("dob", 8), ("born", 6), ("date of issue", 6), ("issue date", 6),
        ("statement date", 6), ("letter date", 6), ("invoice date", 5), ("issued", 4), ("dated", 4),
        ("last payment", 4), ("paid on", 4), ("printed", 4), ("since", 3), ("received", 3),
        ("previous", 3), ("period", 2), ("from", 2), ("sent", 2),
    ]

    /// Picks the most likely due date: the date whose preceding words most
    /// look like "pay by" / "due" and least like "date of issue".
    static func dueDate(in text: String, now: Date, calendar: Calendar) -> Date? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let ns = text as NSString
        let today = calendar.startOfDay(for: now)
        let oldCutoff = calendar.date(byAdding: .day, value: -45, to: today) ?? today
        let farCutoff = calendar.date(byAdding: .year, value: 2, to: today) ?? today

        var bestDate: Date?
        var bestScore = Int.min
        var bestLocation = -1

        for match in detector.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
            guard let date = match.date else { continue }
            let matched = ns.substring(with: match.range)
            guard looksLikeCalendarDate(matched) else { continue }

            let start = max(0, match.range.location - 45)
            let before = ns.substring(with: NSRange(location: start, length: match.range.location - start))

            var score = 0
            for (word, weight) in dueWords where occurrences(of: word, in: before) > 0 { score += weight }
            for (word, weight) in notDueWords where occurrences(of: word, in: before) > 0 { score -= weight }

            let day = calendar.startOfDay(for: date)
            if day > today {
                score += 3
            } else if day == today {
                score += 1
            } else if day < oldCutoff {
                score -= 6
            }
            if day > farCutoff { score -= 6 }

            // Ties go to the later date in the letter: the letter's own date is usually at the top.
            if score > bestScore || (score == bestScore && match.range.location > bestLocation) {
                bestScore = score
                bestDate = day
                bestLocation = match.range.location
            }
        }
        guard let bestDate, bestScore >= 3 else { return nil }
        return bestDate
    }

    /// Rejects detector matches that are only times ("9:30am") or bare weekdays.
    static func looksLikeCalendarDate(_ string: String) -> Bool {
        let pattern = "\\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\\b|\\d{1,2}\\s*[/.\\-]\\s*\\d{1,2}|\\d{4}-\\d{2}-\\d{2}"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        return regex.firstMatch(in: string, options: [], range: NSRange(location: 0, length: (string as NSString).length)) != nil
    }

    // MARK: - Amount

    private static let amountWords: [(String, Int)] = [
        ("amount due", 6), ("total due", 6), ("to pay", 5), ("amount to pay", 6), ("owe", 4), ("balance", 3),
        ("total", 3), ("premium", 3), ("penalty", 3), ("pay", 2), ("due", 2), ("charge", 2),
    ]
    private static let notAmountWords: [(String, Int)] = [
        ("previous", 4), ("last bill", 4), ("paid", 3), ("credit", 2), ("save", 2), ("discount", 1), ("minimum", 1),
    ]

    static func amount(in text: String) -> (value: Double, currency: String)? {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        var candidates: [(value: Double, currency: String, score: Int)] = []

        let symbolPattern = "([£$€])\\s?(\\d{1,3}(?:,\\d{3})+|\\d+)(\\.\\d{1,2})?"
        if let regex = try? NSRegularExpression(pattern: symbolPattern) {
            for match in regex.matches(in: text, options: [], range: range) {
                let symbol = ns.substring(with: match.range(at: 1))
                let whole = ns.substring(with: match.range(at: 2)).replacingOccurrences(of: ",", with: "")
                let fractionRange = match.range(at: 3)
                let fraction = fractionRange.location != NSNotFound ? ns.substring(with: fractionRange) : ""
                guard let value = Double(whole + fraction), value > 0 else { continue }
                candidates.append((value, currencyCode(forSymbol: symbol), amountScore(ns, before: match.range.location)))
            }
        }

        let codePattern = "(\\d{1,3}(?:,\\d{3})+|\\d+)(\\.\\d{1,2})?\\s?(GBP|EUR|USD)\\b"
        if let regex = try? NSRegularExpression(pattern: codePattern) {
            for match in regex.matches(in: text, options: [], range: range) {
                let whole = ns.substring(with: match.range(at: 1)).replacingOccurrences(of: ",", with: "")
                let fractionRange = match.range(at: 2)
                let fraction = fractionRange.location != NSNotFound ? ns.substring(with: fractionRange) : ""
                let code = ns.substring(with: match.range(at: 3))
                guard let value = Double(whole + fraction), value > 0 else { continue }
                candidates.append((value, code, amountScore(ns, before: match.range.location)))
            }
        }

        let best = candidates.max { lhs, rhs in
            lhs.score != rhs.score ? lhs.score < rhs.score : lhs.value < rhs.value
        }
        guard let best else { return nil }
        return (best.value, best.currency)
    }

    private static func amountScore(_ ns: NSString, before location: Int) -> Int {
        let start = max(0, location - 40)
        let context = ns.substring(with: NSRange(location: start, length: location - start))
        var score = 0
        for (word, weight) in amountWords where occurrences(of: word, in: context) > 0 { score += weight }
        for (word, weight) in notAmountWords where occurrences(of: word, in: context) > 0 { score -= weight }
        return score
    }

    private static func currencyCode(forSymbol symbol: String) -> String {
        switch symbol {
        case "£": return "GBP"
        case "€": return "EUR"
        case "$": return "USD"
        default: return MoneyFormat.defaultCurrency
        }
    }

    // MARK: - Reference

    static func reference(in text: String) -> String? {
        let labels = [
            "reference number", "reference no\\.?", "booking reference", "reference", "our ref\\.?", "your ref\\.?", "ref\\.?",
            "account number", "account no\\.?", "customer number", "customer no\\.?", "policy number", "policy no\\.?",
            "invoice number", "invoice no\\.?", "penalty charge notice number", "pcn number", "pcn no\\.?", "pcn",
            "claim number", "case number", "membership number", "licence number", "nhs number", "utr",
        ].joined(separator: "|")
        let pattern = "\\b(?:\(labels))(?![a-z])\\s*(?:number|no\\.?)?\\s*[:#.\\-]?\\s*([A-Z0-9](?:[A-Z0-9\\-/]|\\s(?=[0-9])){3,30})"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        for match in regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
            let candidate = ns.substring(with: match.range(at: 1))
                .trimmingCharacters(in: CharacterSet(charactersIn: "-/ ").union(.whitespacesAndNewlines))
            guard candidate.count >= 4, candidate.rangeOfCharacter(from: .decimalDigits) != nil else { continue }
            return candidate
        }
        return nil
    }
}

/// Parses an amount typed by the user, accepting "84.20", "84,20" and "1,234.50".
enum AmountParser {
    static func parse(_ text: String) -> Double? {
        let digits: ClosedRange<Character> = "0"..."9"
        var s = String(text.filter { digits.contains($0) || $0 == "." || $0 == "," })
        guard !s.isEmpty else { return nil }
        if s.contains(".") && s.contains(",") {
            if let lastDot = s.lastIndex(of: "."), let lastComma = s.lastIndex(of: ","), lastComma > lastDot {
                s = s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            } else {
                s = s.replacingOccurrences(of: ",", with: "")
            }
        } else if s.contains(",") {
            let parts = s.split(separator: ",", omittingEmptySubsequences: false)
            if parts.count == 2, parts[1].count <= 2 {
                s = s.replacingOccurrences(of: ",", with: ".")
            } else {
                s = s.replacingOccurrences(of: ",", with: "")
            }
        }
        guard let value = Double(s), value > 0 else { return nil }
        return value
    }

    static func editableText(_ amount: Double?) -> String {
        guard let amount else { return "" }
        return String(format: "%.2f", amount)
    }
}
