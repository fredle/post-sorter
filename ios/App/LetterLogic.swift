import Foundation
import SwiftData
import UIKit

// MARK: - Grouping

enum DueBucket: String, CaseIterable, Identifiable {
    case overdue, thisWeek, later

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overdue: return "Overdue"
        case .thisWeek: return "This week"
        case .later: return "Later"
        }
    }
}

enum LetterGrouping {
    static func bucket(for due: Date?, now: Date, calendar: Calendar = .current) -> DueBucket {
        guard let due else { return .later }
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: due)
        if day < today { return .overdue }
        if let weekEnd = calendar.date(byAdding: .day, value: 7, to: today), day < weekEnd { return .thisWeek }
        return .later
    }

    /// Soonest due first; letters without a date go last, newest first.
    static func dueOrder(_ a: (due: Date?, created: Date), _ b: (due: Date?, created: Date)) -> Bool {
        switch (a.due, b.due) {
        case let (x?, y?): return x == y ? a.created > b.created : x < y
        case (.some, .none): return true
        case (.none, .some): return false
        case (.none, .none): return a.created > b.created
        }
    }
}

enum DueText {
    static func days(until due: Date, now: Date, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: due)).day ?? 0
    }

    static func relative(_ due: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let count = DueText.days(until: due, now: now, calendar: calendar)
        switch count {
        case 0: return "Due today"
        case 1: return "Due tomorrow"
        case 2...6: return "Due in \(count) days"
        case -1: return "1 day overdue"
        case ..<(-1): return "\(-count) days overdue"
        default: return "Due " + due.formatted(.dateTime.day().month(.abbreviated))
        }
    }
}

// MARK: - Search

enum LetterSearch {
    /// Every word of the query must appear in at least one field.
    static func matches(_ query: String, fields: [String]) -> Bool {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return true }
        return terms.allSatisfy { term in
            fields.contains { $0.localizedStandardContains(term) }
        }
    }
}

// MARK: - Sender memory

struct SenderRecord {
    let key: String
    let name: String
    let kind: LetterKind
}

enum SenderMemory {
    /// "British Gas Ltd." and "BRITISH GAS LTD" share the key "britishgasltd".
    static func key(for name: String) -> String {
        String(name.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// The remembered sender for this letter: same name, or a known name found near the top of the text.
    static func match(sender: String, text: String, known: [SenderRecord]) -> SenderRecord? {
        let senderKey = key(for: sender)
        if !senderKey.isEmpty, let exact = known.first(where: { $0.key == senderKey }) {
            return exact
        }
        let head = key(for: String(text.prefix(800)))
        guard !head.isEmpty else { return nil }
        return known
            .filter { $0.key.count >= 4 && head.contains($0.key) }
            .max { $0.key.count < $1.key.count }
    }
}

// MARK: - Draft

/// The editable copy shown on the review screen. Nothing is stored until Save.
struct LetterDraft: Identifiable {
    let id = UUID()
    var images: [UIImage]
    var fullText: String
    var sender = ""
    var kind: LetterKind = .other
    var summary = ""
    var action = ""
    var needsAction = true
    var hasDueDate = false
    var dueDate: Date
    var amountText = ""
    var currency: String
    var reference = ""
    var reminderDaysBefore: Int
    var addToCalendar = false
    var source: ExtractionSource?
    var recognisedSender = false

    static func defaultDueDate(now: Date = Date()) -> Date {
        let today = Calendar.current.startOfDay(for: now)
        return Calendar.current.date(byAdding: .day, value: 14, to: today) ?? today
    }

    init(analysis: AnalysisResult, daysBefore: Int) {
        let fields = analysis.fields
        images = analysis.images
        fullText = analysis.text
        sender = fields.sender
        kind = fields.kind
        summary = fields.summary
        action = fields.action
        needsAction = fields.needsAction
        hasDueDate = fields.dueDate != nil
        dueDate = fields.dueDate ?? LetterDraft.defaultDueDate()
        amountText = AmountParser.editableText(fields.amount)
        currency = fields.currency ?? MoneyFormat.defaultCurrency
        reference = fields.reference
        reminderDaysBefore = daysBefore
        source = analysis.source
    }

    init(letter: Letter, images: [UIImage]) {
        self.images = images
        fullText = letter.fullText
        sender = letter.sender
        kind = letter.kind
        summary = letter.summary
        action = letter.action
        needsAction = letter.needsAction
        hasDueDate = letter.dueDate != nil
        dueDate = letter.dueDate ?? LetterDraft.defaultDueDate()
        amountText = AmountParser.editableText(letter.amount)
        currency = letter.currency
        reference = letter.reference
        reminderDaysBefore = letter.reminderDaysBefore
        source = nil
    }

    /// Uses what the user told us last time about this sender.
    mutating func apply(_ remembered: SenderRecord) {
        kind = remembered.kind
        if sender.isEmpty || SenderMemory.key(for: sender) == remembered.key {
            sender = remembered.name
        }
        if summary.isEmpty || summary.hasPrefix(LetterKind.other.summaryNoun) {
            summary = PatternExtractor.summary(kind: kind, sender: sender, amount: AmountParser.parse(amountText), currency: currency)
        }
        if needsAction && action.isEmpty {
            action = kind.suggestedAction(amount: AmountParser.parse(amountText), currency: currency)
        }
        if kind.usuallyNeedsAction { needsAction = true }
        recognisedSender = true
    }

    var willHaveReminders: Bool { needsAction && hasDueDate }
}

// MARK: - Saving

enum ReviewMode {
    case new
    case edit(Letter)

    var isNew: Bool {
        if case .new = self { return true }
        return false
    }
}

@MainActor
enum LetterRepository {
    static func save(_ draft: LetterDraft, mode: ReviewMode, context: ModelContext) throws -> Letter {
        let letter: Letter
        switch mode {
        case .new:
            let names = try ImageStore.save(draft.images)
            letter = Letter(imageFileNames: names, fullText: draft.fullText)
            context.insert(letter)
        case .edit(let existing):
            letter = existing
        }

        letter.sender = draft.sender.trimmingCharacters(in: .whitespacesAndNewlines)
        letter.kind = draft.kind
        letter.summary = draft.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        letter.action = draft.needsAction ? draft.action.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        letter.needsAction = draft.needsAction
        letter.dueDate = draft.willHaveReminders ? Calendar.current.startOfDay(for: draft.dueDate) : nil
        letter.amount = AmountParser.parse(draft.amountText)
        letter.currency = draft.currency
        letter.reference = draft.reference.trimmingCharacters(in: .whitespacesAndNewlines)
        letter.reminderDaysBefore = max(0, draft.reminderDaysBefore)
        if letter.summary.isEmpty {
            letter.summary = PatternExtractor.summary(kind: letter.kind, sender: letter.sender, amount: letter.amount, currency: letter.currency)
        }

        remember(sender: letter.sender, kind: letter.kind, context: context)
        try context.save()
        ReminderScheduler.schedule(letter)
        return letter
    }

    static func remember(sender: String, kind: LetterKind, context: ModelContext) {
        let key = SenderMemory.key(for: sender)
        guard key.count >= 2 else { return }
        let all = (try? context.fetch(FetchDescriptor<KnownSender>())) ?? []
        if let existing = all.first(where: { $0.key == key }) {
            existing.name = sender
            existing.kindRaw = kind.rawValue
            existing.lastSeen = Date()
        } else {
            context.insert(KnownSender(key: key, name: sender, kind: kind))
        }
    }

    static func markDone(_ letter: Letter, context: ModelContext) {
        letter.isDone = true
        letter.doneAt = Date()
        ReminderScheduler.cancel(letter)
        try? context.save()
    }

    static func reopen(_ letter: Letter, context: ModelContext) {
        letter.isDone = false
        letter.doneAt = nil
        letter.needsAction = true
        if letter.action.isEmpty {
            letter.action = letter.kind.suggestedAction(amount: letter.amount, currency: letter.currency)
        }
        try? context.save()
        ReminderScheduler.schedule(letter)
    }

    static func delete(_ letter: Letter, context: ModelContext) {
        ReminderScheduler.cancel(letter)
        ImageStore.delete(letter.imageFileNames)
        context.delete(letter)
        try? context.save()
    }
}
