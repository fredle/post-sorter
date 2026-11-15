import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple Intelligence extraction with the on-device Foundation Models framework.
/// Returns nil whenever the model is missing, not ready or fails, so callers
/// fall back to `PatternExtractor`.
enum OnDeviceModel {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability {
                return true
            }
        }
        #endif
        return false
    }

    static func extract(text: String, now: Date) async -> ExtractedFields? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return await FoundationModelExtractor.extract(text: text, now: now)
        }
        #endif
        return nil
    }

    /// Parses the model's "YYYY-MM-DD" date.
    static func parseISODate(_ string: String, calendar: Calendar = .current) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: String(trimmed.prefix(10))) else { return nil }
        return calendar.startOfDay(for: date)
    }

    static func kind(from string: String) -> LetterKind {
        let lower = string.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return LetterKind.allCases.first { lower == $0.rawValue || lower.hasPrefix($0.rawValue) } ?? .other
    }

    static func currencyCode(from string: String) -> String? {
        let code = string.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        switch code {
        case "": return nil
        case "£": return "GBP"
        case "€": return "EUR"
        case "$": return "USD"
        default: return code.count == 3 ? code : nil
        }
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
struct GeneratedLetter {
    @Guide(description: "Who sent the letter: the company, organisation or person, for example 'British Gas' or 'Leeds City Council'. Never the recipient.")
    var sender: String

    @Guide(description: "Exactly one of: bill, renewal, fine, appointment, tax, school, bank, medical, other")
    var documentType: String

    @Guide(description: "One short sentence saying what the letter is about")
    var summary: String

    @Guide(description: "The single thing the reader needs to do, starting with a verb, for example 'Pay £84.20' or 'Call to rebook the appointment'. Empty if nothing needs doing.")
    var action: String

    @Guide(description: "The date by which the action must be done, or the date of the appointment, written as YYYY-MM-DD. Empty if the letter gives no such date. Never the date the letter was written.")
    var dueDate: String

    @Guide(description: "The amount the reader has to pay, as a plain number such as 84.20. Empty if there is nothing to pay.")
    var amount: String

    @Guide(description: "ISO 4217 currency code of the amount, such as GBP, EUR or USD. Empty if there is no amount.")
    var currency: String

    @Guide(description: "The main reference, account, policy or penalty charge number the reader would quote. Empty if none.")
    var reference: String

    @Guide(description: "True if the reader has to do something, false if the letter is for information only")
    var needsAction: Bool
}

@available(iOS 26.0, *)
enum FoundationModelExtractor {
    static func extract(text: String, now: Date) async -> ExtractedFields? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }

        let session = LanguageModelSession(instructions: "You read letters and bills that a person received in the post and pull out what they need to act on. Use only information written in the letter. Leave a field empty when the letter does not say it. Text was read from a photo, so expect small recognition errors.")

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let prompt = "Today's date is \(formatter.string(from: now)). Extract the details from this letter.\n\nLETTER:\n\(String(text.prefix(5000)))"

        do {
            let response = try await session.respond(to: prompt, generating: GeneratedLetter.self)
            let generated = response.content
            var fields = ExtractedFields()
            fields.sender = generated.sender.trimmingCharacters(in: .whitespacesAndNewlines)
            fields.kind = OnDeviceModel.kind(from: generated.documentType)
            fields.summary = generated.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            fields.action = generated.action.trimmingCharacters(in: .whitespacesAndNewlines)
            fields.dueDate = OnDeviceModel.parseISODate(generated.dueDate)
            fields.amount = AmountParser.parse(generated.amount)
            fields.currency = OnDeviceModel.currencyCode(from: generated.currency)
            fields.reference = generated.reference.trimmingCharacters(in: .whitespacesAndNewlines)
            fields.needsAction = generated.needsAction || fields.dueDate != nil
            return fields
        } catch {
            return nil
        }
    }
}
#endif
