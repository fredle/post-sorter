import PhotosUI
import SwiftData
import SwiftUI
import VisionKit

/// The system document camera.
struct DocumentScannerView: UIViewControllerRepresentable {
    let onFinish: ([UIImage]) -> Void
    let onCancel: () -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocumentScannerView

        init(parent: DocumentScannerView) {
            self.parent = parent
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            var images: [UIImage] = []
            for index in 0..<scan.pageCount {
                images.append(scan.imageOfPage(at: index))
            }
            parent.onFinish(images)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            parent.onError("The camera couldn't scan the letter. \(error.localizedDescription)")
        }
    }
}

/// Reads the pages, then shows the review screen. Presented as a sheet.
struct ScanFlowView: View {
    let request: ScanRequest

    @Environment(\.dismiss) private var dismiss
    @Query private var knownSenders: [KnownSender]
    @AppStorage(SettingsKeys.defaultDaysBefore) private var defaultDaysBefore = AppSettings.fallbackDaysBefore

    @State private var phase: Phase = .reading

    enum Phase {
        case reading
        case review(LetterDraft)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            switch phase {
            case .reading:
                ReadingView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { dismiss() }
                        }
                    }
            case .review(let draft):
                ReviewView(draft: draft, mode: .new) {
                    dismiss()
                }
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't read that", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Close") { dismiss() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .interactiveDismissDisabled()
        .task {
            await run()
        }
    }

    private func run() async {
        var images: [UIImage] = []
        var embeddedText: String?

        switch request.source {
        case .images(let scanned):
            images = scanned
        case .photos(let items):
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    images.append(image)
                }
            }
        case .file(let url):
            do {
                let loaded = try FileLoader.load(url)
                images = loaded.images
                embeddedText = loaded.text
            } catch {
                phase = .failed(error.localizedDescription)
                return
            }
        }

        guard !images.isEmpty else {
            phase = .failed("No pages were found. Try scanning the letter again or choose a different photo.")
            return
        }

        let analysis = await LetterAnalyzer.analyze(images: images, embeddedText: embeddedText)
        var draft = LetterDraft(analysis: analysis, daysBefore: defaultDaysBefore)
        let records = knownSenders.map { SenderRecord(key: $0.key, name: $0.name, kind: $0.kind) }
        if let remembered = SenderMemory.match(sender: draft.sender, text: draft.fullText, known: records) {
            draft.apply(remembered)
        }
        withAnimation { phase = .review(draft) }
    }
}

struct ReadingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Reading your letter…")
                .font(.headline)
            Text("This happens on your iPhone. Nothing is uploaded.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PageSelection: Identifiable {
    let id: Int
}

/// A horizontal strip of page thumbnails; tapping one opens it full screen.
struct PageStrip: View {
    let images: [UIImage]
    @State private var selection: PageSelection?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(images.indices, id: \.self) { index in
                    Button {
                        selection = PageSelection(id: index)
                    } label: {
                        Image(uiImage: images[index])
                            .resizable()
                            .scaledToFit()
                            .frame(height: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Page \(index + 1) of \(images.count)")
                    .accessibilityHint("Opens the page full screen")
                }
            }
            .padding(.vertical, 4)
        }
        .fullScreenCover(item: $selection) { selected in
            PageViewer(pages: images, start: selected.id)
        }
    }
}

struct ReviewView: View {
    let mode: ReviewMode
    let onFinish: () -> Void

    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKeys.reminderMinutes) private var reminderMinutes = AppSettings.fallbackReminderMinutes
    @State private var draft: LetterDraft
    @State private var confirmDiscard = false
    @State private var errorMessage: String?
    @State private var calendarError: String?
    @State private var isSaving = false

    init(draft: LetterDraft, mode: ReviewMode, onFinish: @escaping () -> Void) {
        self.mode = mode
        self.onFinish = onFinish
        _draft = State(initialValue: draft)
    }

    private var currencies: [String] {
        var codes = MoneyFormat.commonCurrencies
        if !codes.contains(draft.currency) { codes.insert(draft.currency, at: 0) }
        return codes
    }

    var body: some View {
        Form {
            if !draft.images.isEmpty {
                Section {
                    PageStrip(images: draft.images)
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }
            }

            if let source = draft.source {
                Section {
                    Label(source.message, systemImage: source.symbol)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if draft.recognisedSender {
                        Label("You've had post from \(draft.sender.isEmpty ? "this sender" : draft.sender) before, so the type is set from last time.", systemImage: "person.crop.circle.badge.checkmark")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Letter") {
                TextField("Sender", text: $draft.sender)
                    .textInputAutocapitalization(.words)
                Picker("Type", selection: $draft.kind) {
                    ForEach(LetterKind.allCases) { kind in
                        Label(kind.title, systemImage: kind.symbol).tag(kind)
                    }
                }
                TextField("Summary", text: $draft.summary, axis: .vertical)
                    .lineLimit(1...4)
            }

            Section {
                Toggle("Needs action", isOn: $draft.needsAction.animation())
                if draft.needsAction {
                    TextField("What to do, e.g. Pay the bill", text: $draft.action, axis: .vertical)
                        .lineLimit(1...4)
                    Toggle("Has a due date", isOn: $draft.hasDueDate.animation())
                    if draft.hasDueDate {
                        DatePicker("Due date", selection: $draft.dueDate, displayedComponents: .date)
                    }
                }
            } header: {
                Text("What to do")
            } footer: {
                if !draft.needsAction {
                    Text("Letters that need nothing doing are saved straight to Filed.")
                }
            }

            Section("Payment and reference") {
                HStack {
                    TextField("Amount", text: $draft.amountText)
                        .keyboardType(.decimalPad)
                    Picker("Currency", selection: $draft.currency) {
                        ForEach(currencies, id: \.self) { code in
                            Text(code).tag(code)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                TextField("Reference number", text: $draft.reference)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            }

            if draft.willHaveReminders {
                Section {
                    Stepper(value: $draft.reminderDaysBefore, in: 0...30) {
                        Text(ReminderText.daysBefore(draft.reminderDaysBefore))
                    }
                    if mode.isNew {
                        Toggle("Add to Calendar", isOn: $draft.addToCalendar)
                    }
                } header: {
                    Text("Reminders")
                } footer: {
                    Text("Notifications arrive at \(ReminderText.time(minutes: reminderMinutes)). Change the time in Settings.")
                }
            }

            Section("Recognised text") {
                if draft.fullText.isEmpty {
                    Text("No text was found on these pages.")
                        .foregroundStyle(.secondary)
                } else {
                    DisclosureGroup("Show text") {
                        Text(draft.fullText)
                            .font(.footnote)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(mode.isNew ? "Check details" : "Edit letter")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    if mode.isNew { confirmDiscard = true } else { onFinish() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .fontWeight(.semibold)
                    .disabled(isSaving)
            }
        }
        .confirmationDialog("Discard this letter?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { onFinish() }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("Nothing has been saved yet.")
        }
        .alert(
            "Couldn't save",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert(
            "Saved, but not added to Calendar",
            isPresented: Binding(get: { calendarError != nil }, set: { if !$0 { calendarError = nil } })
        ) {
            Button("OK", role: .cancel) { onFinish() }
        } message: {
            Text(calendarError ?? "")
        }
    }

    private func save() {
        isSaving = true
        let letter: Letter
        do {
            letter = try LetterRepository.save(draft, mode: mode, context: context)
        } catch {
            errorMessage = "The letter couldn't be stored on this iPhone. \(error.localizedDescription)"
            isSaving = false
            return
        }

        guard mode.isNew, draft.addToCalendar, draft.willHaveReminders else {
            onFinish()
            return
        }
        Task {
            do {
                try await CalendarExporter.add(letter)
                letter.addedToCalendar = true
                try? context.save()
                onFinish()
            } catch {
                calendarError = error.localizedDescription
            }
        }
    }
}
