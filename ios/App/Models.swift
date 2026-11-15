import Foundation
import SwiftData

/// What kind of letter this is. Stored on `Letter` as its raw string.
enum LetterKind: String, CaseIterable, Identifiable, Codable {
    case bill, renewal, fine, appointment, tax, school, bank, medical, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bill: return "Bill"
        case .renewal: return "Renewal"
        case .fine: return "Fine"
        case .appointment: return "Appointment"
        case .tax: return "Tax"
        case .school: return "School"
        case .bank: return "Bank"
        case .medical: return "Medical"
        case .other: return "Other"
        }
    }

    /// Used when writing a one-line summary, e.g. "Penalty notice from Leeds City Council".
    var summaryNoun: String {
        switch self {
        case .bill: return "Bill"
        case .renewal: return "Renewal notice"
        case .fine: return "Penalty notice"
        case .appointment: return "Appointment letter"
        case .tax: return "Tax letter"
        case .school: return "School letter"
        case .bank: return "Bank letter"
        case .medical: return "Medical letter"
        case .other: return "Letter"
        }
    }

    var symbol: String {
        switch self {
        case .bill: return "creditcard"
        case .renewal: return "arrow.triangle.2.circlepath"
        case .fine: return "exclamationmark.triangle"
        case .appointment: return "calendar"
        case .tax: return "building.columns"
        case .school: return "graduationcap"
        case .bank: return "banknote"
        case .medical: return "cross.case"
        case .other: return "envelope"
        }
    }

    /// Kinds that normally ask the reader to do something even when no date is found.
    var usuallyNeedsAction: Bool {
        switch self {
        case .bank, .medical, .other: return false
        default: return true
        }
    }

    func suggestedAction(amount: Double?, currency: String) -> String {
        let money = amount.map { MoneyFormat.string($0, currency: currency) }
        switch self {
        case .bill: return money.map { "Pay \($0)" } ?? "Pay the bill"
        case .renewal: return "Check the renewal price and compare quotes"
        case .fine: return money.map { "Pay \($0) or appeal" } ?? "Pay or appeal the fine"
        case .appointment: return "Attend the appointment or rearrange it"
        case .tax: return money.map { "Pay \($0)" } ?? "Check and pay the tax due"
        case .school: return "Read and return the form"
        case .bank: return "Check the letter against your account"
        case .medical: return "Read and follow the instructions"
        case .other: return "Read and decide what to do"
        }
    }
}

@Model
final class Letter {
    var uid: UUID = UUID()
    var createdAt: Date = Date()
    var sender: String = ""
    var kindRaw: String = "other"
    var summary: String = ""
    var action: String = ""
    var needsAction: Bool = true
    var dueDate: Date? = nil
    var amount: Double? = nil
    var currency: String = "GBP"
    var reference: String = ""
    var fullText: String = ""
    var imageFileNames: [String] = []
    var isDone: Bool = false
    var doneAt: Date? = nil
    var reminderDaysBefore: Int = 3
    var addedToCalendar: Bool = false

    init(imageFileNames: [String], fullText: String, createdAt: Date = Date()) {
        self.uid = UUID()
        self.createdAt = createdAt
        self.imageFileNames = imageFileNames
        self.fullText = fullText
    }

    var kind: LetterKind {
        get { LetterKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }

    /// Done letters and letters that need nothing doing live in "Filed".
    var isFiled: Bool { isDone || !needsAction }

    var displaySender: String { sender.isEmpty ? kind.summaryNoun : sender }

    var formattedAmount: String? {
        amount.map { MoneyFormat.string($0, currency: currency) }
    }

    var searchableFields: [String] {
        [sender, summary, action, reference, fullText, kind.title]
    }
}

/// A sender seen before, so the next letter from them gets its type prefilled.
@Model
final class KnownSender {
    @Attribute(.unique) var key: String = ""
    var name: String = ""
    var kindRaw: String = "other"
    var lastSeen: Date = Date()

    init(key: String, name: String, kind: LetterKind) {
        self.key = key
        self.name = name
        self.kindRaw = kind.rawValue
        self.lastSeen = Date()
    }

    var kind: LetterKind { LetterKind(rawValue: kindRaw) ?? .other }
}

enum MoneyFormat {
    static func string(_ amount: Double, currency: String) -> String {
        amount.formatted(.currency(code: currency.isEmpty ? "GBP" : currency))
    }

    static let commonCurrencies = ["GBP", "EUR", "USD", "CAD", "AUD", "NZD", "CHF", "SEK", "NOK", "DKK", "PLN", "JPY", "INR", "ZAR"]

    static var defaultCurrency: String {
        Locale.current.currency?.identifier ?? "GBP"
    }
}
