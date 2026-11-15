import SwiftData
import SwiftUI
import UIKit

/// Screenshot mode for the App Store images. Only active when the app is
/// launched with `-demo` (by the screenshots workflow in the simulator); it
/// replaces the store with made-up letters and opens the screen named by
/// `-demoScreen` (home, filed, detail, review, settings).
enum DemoMode {
    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains("-demo") }

    static var screen: String {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-demoScreen"), i + 1 < args.count { return args[i + 1] }
        return "home"
    }

    static let featuredSender = "Northfield Energy"

    struct Sample {
        var sender: String
        var kind: LetterKind
        var summary: String
        var action: String
        var dueInDays: Int?
        var amount: Double?
        var reference: String
        var needsAction = true
        var isDone = false
        var heading: String
        var body: [String]
    }

    static let samples: [Sample] = [
        Sample(sender: "Northfield Energy", kind: .bill, summary: "Electricity and gas bill for October",
               action: "Pay £84.20", dueInDays: 3, amount: 84.20, reference: "NE-4471-2093",
               heading: "Your energy bill",
               body: ["Billing period: 1 October to 31 October",
                      "Electricity: £51.35   Gas: £32.85",
                      "Total to pay: £84.20",
                      "Please pay by the date shown below to avoid a late payment charge.",
                      "Account number: NE-4471-2093"]),
        Sample(sender: "Harbour Parking Ltd", kind: .fine, summary: "Parking charge notice, Quay Street car park",
               action: "Pay £60 or appeal", dueInDays: -2, amount: 60, reference: "PCN 88213457",
               heading: "Parking Charge Notice",
               body: ["Vehicle observed parked without a valid ticket.",
                      "Charge: £60, reduced from £100 if paid within 14 days.",
                      "You may appeal within 28 days of the date of this notice.",
                      "Reference: PCN 88213457"]),
        Sample(sender: "Westvale Borough Council", kind: .tax, summary: "Council tax instalment for December",
               action: "Pay £142.00", dueInDays: 6, amount: 142, reference: "CT 1029 3384",
               heading: "Council Tax reminder",
               body: ["Your next instalment of £142.00 is due.",
                      "Pay online, by phone or by Direct Debit.",
                      "Account reference: CT 1029 3384"]),
        Sample(sender: "St Anne's Primary School", kind: .school, summary: "Year 4 museum trip",
               action: "Return the signed consent form", dueInDays: 9, amount: 12, reference: "",
               heading: "Year 4 trip to the Science Museum",
               body: ["Please sign and return the consent form with a contribution of £12.",
                      "Forms must be back with the class teacher before the trip."]),
        Sample(sender: "Brightline Insurance", kind: .renewal, summary: "Car insurance renewal quote",
               action: "Compare quotes before it renews at £612.40", dueInDays: 19, amount: 612.40, reference: "POL-77120-H",
               heading: "Your renewal is coming up",
               body: ["Your policy will renew automatically at £612.40.",
                      "Last year you paid £498.10.",
                      "Policy number: POL-77120-H"]),
        Sample(sender: "Riverside Hospital", kind: .appointment, summary: "Outpatient appointment, 10:40",
               action: "Attend or rearrange the appointment", dueInDays: 24, amount: nil, reference: "MRN 5583012",
               heading: "Outpatient appointment",
               body: ["Your appointment is at 10:40 in Clinic 3, Level 2.",
                      "Please call us if you need to rearrange.",
                      "Hospital number: MRN 5583012"]),
        Sample(sender: "Meridian Bank", kind: .bank, summary: "Annual summary of fees", action: "",
               dueInDays: nil, amount: nil, reference: "", needsAction: false,
               heading: "Your annual summary of fees",
               body: ["This statement shows the fees you paid on your current account this year.",
                      "No action is needed."]),
        Sample(sender: "Clearwater Water", kind: .bill, summary: "Water bill, paid", action: "Pay £38.50",
               dueInDays: -12, amount: 38.50, reference: "CW 220 914", isDone: true,
               heading: "Your water bill",
               body: ["Amount due: £38.50", "Customer reference: CW 220 914"]),
    ]

    @MainActor
    static func seed(_ context: ModelContext) {
        try? context.delete(model: Letter.self)
        try? context.delete(model: KnownSender.self)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        for (index, sample) in samples.enumerated() {
            let names = (try? ImageStore.save([page(for: sample)])) ?? []
            let created = calendar.date(byAdding: .hour, value: -6 * (index + 1), to: Date()) ?? Date()
            let letter = Letter(imageFileNames: names, fullText: text(for: sample), createdAt: created)
            letter.sender = sample.sender
            letter.kind = sample.kind
            letter.summary = sample.summary
            letter.action = sample.action
            letter.needsAction = sample.needsAction
            letter.dueDate = sample.dueInDays.flatMap { calendar.date(byAdding: .day, value: $0, to: today) }
            letter.amount = sample.amount
            letter.currency = "GBP"
            letter.reference = sample.reference
            letter.isDone = sample.isDone
            letter.doneAt = sample.isDone ? created : nil
            context.insert(letter)
        }
        try? context.save()
    }

    static func text(for sample: Sample) -> String {
        ([sample.sender, sample.heading] + sample.body).joined(separator: "\n")
    }

    /// The scan the review screen shows, as if just read from the camera.
    static func draft() -> LetterDraft {
        let sample = samples[0]
        let today = Calendar.current.startOfDay(for: Date())
        var fields = ExtractedFields()
        fields.sender = sample.sender
        fields.kind = sample.kind
        fields.summary = sample.summary
        fields.action = sample.action
        fields.dueDate = Calendar.current.date(byAdding: .day, value: sample.dueInDays ?? 3, to: today)
        fields.amount = sample.amount
        fields.currency = "GBP"
        fields.reference = sample.reference
        fields.needsAction = true
        let analysis = AnalysisResult(images: [page(for: sample)], text: text(for: sample), fields: fields, source: .appleIntelligence)
        var draft = LetterDraft(analysis: analysis, daysBefore: 3)
        draft.recognisedSender = true
        return draft
    }

    /// Draws a plausible A4 letter for the sample.
    static func page(for sample: Sample) -> UIImage {
        let size = CGSize(width: 1240, height: 1754)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            let accent = UIColor(red: 0.16, green: 0.32, blue: 0.55, alpha: 1)
            accent.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: 18))

            func draw(_ string: String, _ font: UIFont, _ color: UIColor, at point: CGPoint, width: CGFloat = 1060) -> CGFloat {
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = 8
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
                let rect = (string as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                             options: [.usesLineFragmentOrigin], attributes: attributes, context: nil)
                (string as NSString).draw(with: CGRect(origin: point, size: CGSize(width: width, height: rect.height)),
                                          options: [.usesLineFragmentOrigin], attributes: attributes, context: nil)
                return rect.height
            }

            _ = draw(sample.sender, .systemFont(ofSize: 54, weight: .bold), accent, at: CGPoint(x: 90, y: 100))
            _ = draw("PO Box 4120\nAnytown AB1 2CD", .systemFont(ofSize: 28), .darkGray, at: CGPoint(x: 90, y: 180))
            _ = draw("Alex Taylor\n14 Elm Grove\nAnytown AB3 4EF", .systemFont(ofSize: 32), .black, at: CGPoint(x: 90, y: 330))

            let formatter = DateFormatter()
            formatter.dateStyle = .long
            let issued = Calendar.current.date(byAdding: .day, value: -5, to: Date()) ?? Date()
            _ = draw("Date: \(formatter.string(from: issued))", .systemFont(ofSize: 30), .black, at: CGPoint(x: 820, y: 330), width: 360)

            var y: CGFloat = 560
            y += draw(sample.heading, .systemFont(ofSize: 46, weight: .semibold), .black, at: CGPoint(x: 90, y: y)) + 40
            for line in sample.body {
                y += draw(line, .systemFont(ofSize: 34), .black, at: CGPoint(x: 90, y: y)) + 26
            }
            if let days = sample.dueInDays {
                let due = Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
                y += 20
                UIColor(red: 0.95, green: 0.96, blue: 0.98, alpha: 1).setFill()
                ctx.fill(CGRect(x: 90, y: y, width: 1060, height: 110))
                _ = draw("Please respond by \(formatter.string(from: due))", .systemFont(ofSize: 38, weight: .semibold),
                         accent, at: CGPoint(x: 120, y: y + 30), width: 1000)
                y += 150
            }
            UIColor(white: 0.85, alpha: 1).setFill()
            for i in 0..<6 {
                ctx.fill(CGRect(x: 90, y: y + 40 + CGFloat(i) * 52, width: i == 5 ? 620 : 1060, height: 16))
            }
        }
    }
}

/// Seeds the demo data, then shows the requested screen.
struct DemoRootView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Letter.createdAt, order: .reverse) private var letters: [Letter]
    @State private var ready = false

    var body: some View {
        Group {
            if !ready {
                Color(.systemGroupedBackground).ignoresSafeArea()
            } else {
                switch DemoMode.screen {
                case "filed":
                    HomeView(initialTab: .filed)
                case "detail":
                    NavigationStack {
                        if let letter = letters.first(where: { $0.sender == DemoMode.featuredSender }) {
                            LetterDetailView(letter: letter)
                        }
                    }
                case "review":
                    NavigationStack {
                        ReviewView(draft: DemoMode.draft(), mode: .new, onFinish: {})
                    }
                case "settings":
                    SettingsView()
                default:
                    HomeView()
                }
            }
        }
        .task {
            guard !ready else { return }
            DemoMode.seed(context)
            ready = true
        }
    }
}
