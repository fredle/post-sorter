import SwiftData
import SwiftUI
import UIKit

struct LetterDetailView: View {
    let letter: Letter

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKeys.reminderMinutes) private var reminderMinutes = AppSettings.fallbackReminderMinutes

    @State private var pages: [UIImage] = []
    @State private var pdfURL: URL?
    @State private var viewer: PageSelection?
    @State private var editDraft: LetterDraft?
    @State private var confirmDelete = false
    @State private var alertTitle = ""
    @State private var alertMessage: String?
    @State private var isAddingToCalendar = false

    var body: some View {
        List {
            if !pages.isEmpty {
                Section {
                    TabView {
                        ForEach(pages.indices, id: \.self) { index in
                            Button {
                                viewer = PageSelection(id: index)
                            } label: {
                                Image(uiImage: pages[index])
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Page \(index + 1) of \(pages.count)")
                            .accessibilityHint("Opens the page full screen with zoom")
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: pages.count > 1 ? .always : .never))
                    .indexViewStyle(.page(backgroundDisplayMode: .always))
                    .frame(height: 360)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label(letter.kind.title, systemImage: letter.kind.symbol)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(letter.displaySender)
                        .font(.title2.bold())
                    if !letter.summary.isEmpty {
                        Text(letter.summary)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }

            Section("What to do") {
                if letter.isDone {
                    Label(doneText, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if !letter.needsAction {
                    Label("No action needed", systemImage: "tray")
                        .foregroundStyle(.secondary)
                }
                if !letter.action.isEmpty {
                    Text(letter.action)
                        .font(.headline)
                }
                if let due = letter.dueDate {
                    LabeledContent("Due") {
                        VStack(alignment: .trailing) {
                            Text(due.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
                            if !letter.isFiled {
                                Text(DueText.relative(due))
                                    .font(.footnote)
                                    .foregroundStyle(LetterGrouping.bucket(for: due, now: Date()) == .overdue ? Color.red : Color.secondary)
                            }
                        }
                        .multilineTextAlignment(.trailing)
                    }
                }
                if let amount = letter.formattedAmount {
                    LabeledContent("Amount", value: amount)
                }
                if !letter.reference.isEmpty {
                    LabeledContent("Reference") {
                        Text(letter.reference)
                            .textSelection(.enabled)
                    }
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = letter.reference
                        } label: {
                            Label("Copy reference", systemImage: "doc.on.doc")
                        }
                    }
                }
                if letter.dueDate == nil && letter.action.isEmpty && letter.amount == nil && letter.reference.isEmpty && letter.needsAction && !letter.isDone {
                    Text("No details yet. Tap Edit to add what to do and by when.")
                        .foregroundStyle(.secondary)
                }
            }

            if let reminderSummary {
                Section("Reminders") {
                    Label(reminderSummary, systemImage: "bell")
                    if letter.addedToCalendar {
                        Label("Added to Calendar", systemImage: "calendar.badge.checkmark")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                if letter.isFiled {
                    Button {
                        LetterRepository.reopen(letter, context: context)
                    } label: {
                        Label("Move back to To do", systemImage: "arrow.uturn.backward")
                    }
                } else {
                    Button {
                        LetterRepository.markDone(letter, context: context)
                    } label: {
                        Label("Mark as done", systemImage: "checkmark.circle")
                    }
                }
                if letter.dueDate != nil {
                    Button(action: addToCalendar) {
                        Label(letter.addedToCalendar ? "Add to Calendar again" : "Add to Calendar", systemImage: "calendar.badge.plus")
                    }
                    .disabled(isAddingToCalendar)
                }
                if let pdfURL {
                    ShareLink(item: pdfURL) {
                        Label("Share as PDF", systemImage: "square.and.arrow.up")
                    }
                }
            }

            Section("Recognised text") {
                if letter.fullText.isEmpty {
                    Text("No text was found on these pages.")
                        .foregroundStyle(.secondary)
                } else {
                    DisclosureGroup("Show text") {
                        Text(letter.fullText)
                            .font(.footnote)
                            .textSelection(.enabled)
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("Delete letter", systemImage: "trash")
                }
            } footer: {
                Text("Added \(letter.createdAt.formatted(date: .long, time: .shortened)).")
            }
        }
        .navigationTitle(letter.displaySender)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") {
                    editDraft = LetterDraft(letter: letter, images: pages)
                }
            }
        }
        .task {
            await loadPages()
        }
        .fullScreenCover(item: $viewer) { selected in
            PageViewer(pages: pages, start: selected.id)
        }
        .sheet(item: $editDraft) { draft in
            NavigationStack {
                ReviewView(draft: draft, mode: .edit(letter)) {
                    editDraft = nil
                }
            }
            .interactiveDismissDisabled()
        }
        .confirmationDialog("Delete this letter?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: deleteLetter)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The letter, its pages and its reminders are removed from this iPhone.")
        }
        .alert(
            alertTitle,
            isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private var doneText: String {
        if let doneAt = letter.doneAt {
            return "Done on \(doneAt.formatted(date: .abbreviated, time: .omitted))"
        }
        return "Done"
    }

    private var reminderSummary: String? {
        guard let due = letter.dueDate, letter.needsAction, !letter.isDone else { return nil }
        let time = ReminderText.time(minutes: reminderMinutes)
        guard DueText.days(until: due, now: Date()) >= 0 else {
            return "The due date has passed, so no more reminders are scheduled."
        }
        switch letter.reminderDaysBefore {
        case 0: return "On the day at \(time)"
        case 1: return "1 day before and on the day, at \(time)"
        default: return "\(letter.reminderDaysBefore) days before and on the day, at \(time)"
        }
    }

    private func loadPages() async {
        guard pages.isEmpty else { return }
        let names = letter.imageFileNames
        let title = letter.displaySender
        let loaded = await Task.detached(priority: .userInitiated) {
            names.compactMap { ImageStore.load($0) }
        }.value
        pages = loaded
        if !loaded.isEmpty {
            pdfURL = await Task.detached(priority: .utility) {
                try? PDFExporter.makePDF(images: loaded, name: title)
            }.value
        }
    }

    private func addToCalendar() {
        isAddingToCalendar = true
        Task {
            do {
                try await CalendarExporter.add(letter)
                letter.addedToCalendar = true
                try? context.save()
                alertTitle = "Added to Calendar"
                alertMessage = "An all-day event is on your calendar for the due date."
            } catch {
                alertTitle = "Couldn't add to Calendar"
                alertMessage = error.localizedDescription
            }
            isAddingToCalendar = false
        }
    }

    private func deleteLetter() {
        let target = letter
        let modelContext = context
        dismiss()
        Task {
            // Let the screen close before the letter it shows is removed.
            try? await Task.sleep(nanoseconds: 450_000_000)
            LetterRepository.delete(target, context: modelContext)
        }
    }
}

/// Full-screen pages with pinch and double-tap zoom.
struct PageViewer: View {
    let pages: [UIImage]
    @State private var index: Int
    @Environment(\.dismiss) private var dismiss

    init(pages: [UIImage], start: Int) {
        self.pages = pages
        _index = State(initialValue: start)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(pages.indices, id: \.self) { page in
                    ZoomableImageView(image: pages[page])
                        .tag(page)
                        .accessibilityLabel("Page \(page + 1) of \(pages.count)")
                }
            }
            .tabViewStyle(.page(indexDisplayMode: pages.count > 1 ? .always : .never))
            .ignoresSafeArea()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.largeTitle)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .white.opacity(0.3))
            }
            .padding()
            .accessibilityLabel("Close")
        }
        .preferredColorScheme(.dark)
    }
}

struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> ZoomingScrollView {
        let scrollView = ZoomingScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 6
        scrollView.bouncesZoom = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.backgroundColor = .black
        scrollView.contentInsetAdjustmentBehavior = .never

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        scrollView.addSubview(imageView)
        scrollView.imageView = imageView
        context.coordinator.imageView = imageView

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        return scrollView
    }

    func updateUIView(_ uiView: ZoomingScrollView, context: Context) {
        if uiView.imageView?.image !== image {
            uiView.imageView?.image = image
            uiView.setZoomScale(1, animated: false)
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView = recognizer.view as? UIScrollView else { return }
            if scrollView.zoomScale > 1.01 {
                scrollView.setZoomScale(1, animated: true)
            } else {
                let point = recognizer.location(in: imageView)
                let scale: CGFloat = 2.5
                let size = CGSize(width: scrollView.bounds.width / scale, height: scrollView.bounds.height / scale)
                let rect = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
                scrollView.zoom(to: rect, animated: true)
            }
        }
    }
}

/// Keeps the image filling the view while it isn't zoomed.
final class ZoomingScrollView: UIScrollView {
    weak var imageView: UIImageView?

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let imageView, zoomScale <= 1.0001 else { return }
        imageView.frame = CGRect(origin: .zero, size: bounds.size)
        contentSize = bounds.size
    }
}
