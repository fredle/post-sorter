import EventKit
import Foundation
import LocalAuthentication
import UIKit
import UserNotifications

// MARK: - Settings

enum SettingsKeys {
    static let defaultDaysBefore = "defaultDaysBefore"
    static let reminderMinutes = "reminderMinutes"
    static let lockEnabled = "lockEnabled"
}

enum AppSettings {
    static let fallbackDaysBefore = 3
    /// 09:00, as minutes after midnight.
    static let fallbackReminderMinutes = 9 * 60

    static var defaultDaysBefore: Int {
        UserDefaults.standard.object(forKey: SettingsKeys.defaultDaysBefore) as? Int ?? fallbackDaysBefore
    }

    static var reminderMinutes: Int {
        UserDefaults.standard.object(forKey: SettingsKeys.reminderMinutes) as? Int ?? fallbackReminderMinutes
    }
}

// MARK: - Images

/// Page images live as JPEG files in Application Support/Letters.
enum ImageStore {
    static var directory: URL {
        let url = URL.applicationSupportDirectory.appending(path: "Letters", directoryHint: .isDirectory)
        if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    static func url(for name: String) -> URL {
        directory.appending(path: name)
    }

    static func save(_ images: [UIImage]) throws -> [String] {
        var names: [String] = []
        do {
            for image in images {
                guard let data = image.jpegData(compressionQuality: 0.8) else { continue }
                let name = UUID().uuidString + ".jpg"
                try data.write(to: url(for: name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                names.append(name)
            }
        } catch {
            delete(names)
            throw error
        }
        return names
    }

    static func load(_ name: String) -> UIImage? {
        guard let data = try? Data(contentsOf: url(for: name)) else { return nil }
        return UIImage(data: data)
    }

    static func delete(_ names: [String]) {
        for name in names {
            try? FileManager.default.removeItem(at: url(for: name))
        }
    }
}

// MARK: - PDF

enum PDFExporter {
    /// Writes the pages to a PDF in the temporary directory, one page per image at A4 width.
    static func makePDF(images: [UIImage], name: String) throws -> URL {
        let width: CGFloat = 595
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: width, height: 842))
        let data = renderer.pdfData { context in
            for image in images {
                let ratio = image.size.width > 0 ? image.size.height / image.size.width : 1.414
                let bounds = CGRect(x: 0, y: 0, width: width, height: width * ratio)
                context.beginPage(withBounds: bounds, pageInfo: [:])
                image.draw(in: bounds)
            }
        }
        let safe = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        let fileName = (safe.trimmingCharacters(in: .whitespaces).isEmpty ? "Letter" : safe) + ".pdf"
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: fileName)
        try data.write(to: url, options: .atomic)
        return url
    }
}

// MARK: - Reminders

/// The plain values needed to schedule a letter's reminders.
struct ReminderPlan {
    let letterID: UUID
    let title: String
    let body: String
    let dueDate: Date?
    let daysBefore: Int
    let minutesOfDay: Int
    let isActive: Bool

    var identifiers: [String] {
        ["\(letterID.uuidString).before", "\(letterID.uuidString).due"]
    }

    struct Fire: Equatable {
        let identifier: String
        let date: Date
        let daysBefore: Int
    }

    /// The reminder times still in the future: N days before the due date and on the day.
    func fireDates(now: Date, calendar: Calendar = .current) -> [Fire] {
        guard isActive, let dueDate else { return [] }
        let day = calendar.startOfDay(for: dueDate)
        guard let onTheDay = calendar.date(byAdding: .minute, value: minutesOfDay, to: day) else { return [] }
        var fires: [Fire] = []
        if daysBefore > 0, let before = calendar.date(byAdding: .day, value: -daysBefore, to: onTheDay), before > now {
            fires.append(Fire(identifier: identifiers[0], date: before, daysBefore: daysBefore))
        }
        if onTheDay > now {
            fires.append(Fire(identifier: identifiers[1], date: onTheDay, daysBefore: 0))
        }
        return fires
    }
}

enum ReminderScheduler {
    @MainActor
    static func plan(for letter: Letter) -> ReminderPlan {
        ReminderPlan(
            letterID: letter.uid,
            title: letter.displaySender,
            body: letter.action.isEmpty ? letter.summary : letter.action,
            dueDate: letter.dueDate,
            daysBefore: letter.reminderDaysBefore,
            minutesOfDay: AppSettings.reminderMinutes,
            isActive: letter.needsAction && !letter.isDone
        )
    }

    @MainActor
    static func schedule(_ letter: Letter) {
        schedule(plan(for: letter))
    }

    @MainActor
    static func rescheduleAll(_ letters: [Letter]) {
        for letter in letters { schedule(letter) }
    }

    @MainActor
    static func cancel(_ letter: Letter) {
        let ids = plan(for: letter).identifiers
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    static func schedule(_ plan: ReminderPlan) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: plan.identifiers)
        let fires = plan.fireDates(now: Date())
        guard !fires.isEmpty else { return }

        var requests: [UNNotificationRequest] = []
        for fire in fires {
            let content = UNMutableNotificationContent()
            switch fire.daysBefore {
            case 0: content.title = "Due today: \(plan.title)"
            case 1: content.title = "Due tomorrow: \(plan.title)"
            default: content.title = "Due in \(fire.daysBefore) days: \(plan.title)"
            }
            content.body = plan.body
            content.sound = .default
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire.date)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            requests.append(UNNotificationRequest(identifier: fire.identifier, content: content, trigger: trigger))
        }

        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            for request in requests {
                center.add(request, withCompletionHandler: nil)
            }
        }
    }
}

enum ReminderText {
    static func daysBefore(_ days: Int) -> String {
        switch days {
        case 0: return "On the day only"
        case 1: return "1 day before and on the day"
        default: return "\(days) days before and on the day"
        }
    }

    static func time(minutes: Int) -> String {
        let date = Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Calendar

enum CalendarExportError: LocalizedError {
    case denied, noCalendar

    var errorDescription: String? {
        switch self {
        case .denied:
            return "Post Sorter can't add events. Allow Calendar access in Settings > Apps > Post Sorter."
        case .noCalendar:
            return "There's no calendar to add the event to."
        }
    }
}

enum CalendarExporter {
    /// Adds an all-day event on the due date, using write-only Calendar access.
    static func addEvent(title: String, notes: String, date: Date) async throws {
        let store = EKEventStore()
        let granted = try await store.requestWriteOnlyAccessToEvents()
        guard granted else { throw CalendarExportError.denied }
        guard let calendar = store.defaultCalendarForNewEvents else { throw CalendarExportError.noCalendar }
        let day = Calendar.current.startOfDay(for: date)
        let event = EKEvent(eventStore: store)
        event.title = title
        event.notes = notes
        event.isAllDay = true
        event.startDate = day
        event.endDate = day
        event.calendar = calendar
        try store.save(event, span: .thisEvent)
    }

    @MainActor
    static func add(_ letter: Letter) async throws {
        guard let due = letter.dueDate else { return }
        let title = letter.action.isEmpty ? letter.displaySender : "\(letter.action) – \(letter.displaySender)"
        var notes = letter.summary
        if !letter.reference.isEmpty { notes += "\nReference: \(letter.reference)" }
        try await addEvent(title: title, notes: notes, date: due)
    }
}

// MARK: - Face ID lock

enum BiometricAuth {
    /// True when the phone has a passcode, so the lock can be used.
    static var canLock: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    static var lockName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return "Passcode"
        }
    }

    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        // Without a passcode nothing can be checked; don't lock the user out.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return true }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}
