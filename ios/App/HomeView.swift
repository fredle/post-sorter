import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

enum HomeTab: String, CaseIterable, Identifiable {
    case todo = "To do"
    case filed = "Filed"

    var id: String { rawValue }
}

struct LetterSection: Identifiable {
    let bucket: DueBucket
    let letters: [Letter]

    var id: DueBucket { bucket }
}

enum ScanSource {
    case images([UIImage])
    case photos([PhotosPickerItem])
    case file(URL)
}

struct ScanRequest: Identifiable {
    let id = UUID()
    let source: ScanSource
}

struct HomeView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Letter.createdAt, order: .reverse) private var letters: [Letter]

    @State private var tab: HomeTab = .todo
    @State private var searchText = ""
    @State private var showScanner = false
    @State private var scannedImages: [UIImage] = []
    @State private var showPhotoPicker = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showFileImporter = false
    @State private var scanRequest: ScanRequest?
    @State private var showSettings = false
    @State private var letterToDelete: Letter?
    @State private var errorMessage: String?
    @State private var didRefreshReminders = false

    var body: some View {
        NavigationStack {
            List {
                Picker("Show", selection: $tab) {
                    ForEach(HomeTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))

                if tab == .todo {
                    todoContent
                } else {
                    filedContent
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Post Sorter")
            .searchable(text: $searchText, prompt: "Sender, reference or any word")
            .navigationDestination(for: Letter.self) { letter in
                LetterDetailView(letter: letter)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    addMenu
                }
            }
            .safeAreaInset(edge: .bottom) {
                bottomBar
            }
        }
        .fullScreenCover(isPresented: $showScanner, onDismiss: presentScannedImages) {
            DocumentScannerView { images in
                scannedImages = images
                showScanner = false
            } onCancel: {
                showScanner = false
            } onError: { message in
                errorMessage = message
                showScanner = false
            }
            .ignoresSafeArea()
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems, maxSelectionCount: 10, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            let chosen = items
            photoItems = []
            present(.photos(chosen))
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.pdf, .image]) { result in
            handleImport(result)
        }
        .sheet(item: $scanRequest) { request in
            ScanFlowView(request: request)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .confirmationDialog(
            "Delete this letter?",
            isPresented: Binding(get: { letterToDelete != nil }, set: { if !$0 { letterToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let letter = letterToDelete {
                    withAnimation { LetterRepository.delete(letter, context: context) }
                }
                letterToDelete = nil
            }
            Button("Cancel", role: .cancel) { letterToDelete = nil }
        } message: {
            Text("The letter, its pages and its reminders are removed from this iPhone.")
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .task {
            // Rebuild pending reminders once per launch, so they match the stored letters.
            guard !didRefreshReminders else { return }
            didRefreshReminders = true
            ReminderScheduler.rescheduleAll(letters.filter { !$0.isFiled })
        }
    }

    // MARK: - Lists

    private var matchingLetters: [Letter] {
        letters.filter { LetterSearch.matches(searchText, fields: $0.searchableFields) }
    }

    private var todoSections: [LetterSection] {
        let now = Date()
        let open = matchingLetters
            .filter { !$0.isFiled }
            .sorted { LetterGrouping.dueOrder(($0.dueDate, $0.createdAt), ($1.dueDate, $1.createdAt)) }
        return DueBucket.allCases.compactMap { bucket in
            let items = open.filter { LetterGrouping.bucket(for: $0.dueDate, now: now) == bucket }
            return items.isEmpty ? nil : LetterSection(bucket: bucket, letters: items)
        }
    }

    private var filedLetters: [Letter] {
        matchingLetters
            .filter { $0.isFiled }
            .sorted { ($0.doneAt ?? $0.createdAt) > ($1.doneAt ?? $1.createdAt) }
    }

    @ViewBuilder
    private var todoContent: some View {
        let sections = todoSections
        if sections.isEmpty {
            emptyState(filed: false)
        } else {
            ForEach(sections) { section in
                Section(section.bucket.title) {
                    ForEach(section.letters) { letter in
                        NavigationLink(value: letter) {
                            LetterRow(letter: letter)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button {
                                withAnimation { LetterRepository.markDone(letter, context: context) }
                            } label: {
                                Label("Done", systemImage: "checkmark")
                            }
                            .tint(.green)
                            Button {
                                letterToDelete = letter
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .tint(.red)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var filedContent: some View {
        let filed = filedLetters
        if filed.isEmpty {
            emptyState(filed: true)
        } else {
            Section {
                ForEach(filed) { letter in
                    NavigationLink(value: letter) {
                        LetterRow(letter: letter)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button {
                            withAnimation { LetterRepository.reopen(letter, context: context) }
                        } label: {
                            Label("To do", systemImage: "arrow.uturn.backward")
                        }
                        .tint(.blue)
                        Button {
                            letterToDelete = letter
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(.red)
                    }
                }
            } footer: {
                Text("Done letters and letters that need nothing doing.")
            }
        }
    }

    @ViewBuilder
    private func emptyState(filed: Bool) -> some View {
        Group {
            if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else if filed {
                ContentUnavailableView(
                    "Nothing filed yet",
                    systemImage: "archivebox",
                    description: Text("Swipe a letter in To do to mark it done, and it moves here.")
                )
            } else if letters.isEmpty {
                ContentUnavailableView {
                    Label("No post to sort", systemImage: "envelope.open")
                } description: {
                    Text("Scan a letter or bill. Post Sorter reads it on your iPhone and tells you what to do and by when.")
                } actions: {
                    Button("Scan a letter", action: startScan)
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ContentUnavailableView(
                    "All done",
                    systemImage: "checkmark.circle",
                    description: Text("Nothing in your post needs doing.")
                )
            }
        }
        .frame(maxWidth: .infinity)
        .listRowBackground(Color.clear)
    }

    // MARK: - Adding letters

    private var addMenu: some View {
        Menu {
            Button(action: startScan) {
                Label("Scan with camera", systemImage: "doc.viewfinder")
            }
            Button {
                showPhotoPicker = true
            } label: {
                Label("Choose photos", systemImage: "photo.on.rectangle")
            }
            Button {
                showFileImporter = true
            } label: {
                Label("Import PDF or image", systemImage: "folder")
            }
        } label: {
            Label("Add letter", systemImage: "plus")
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button(action: startScan) {
                Label("Scan a letter", systemImage: "doc.viewfinder")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Menu {
                Button {
                    showPhotoPicker = true
                } label: {
                    Label("Choose photos", systemImage: "photo.on.rectangle")
                }
                Button {
                    showFileImporter = true
                } label: {
                    Label("Import PDF or image", systemImage: "folder")
                }
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
                    .labelStyle(.iconOnly)
                    .font(.headline)
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityLabel("Import a photo or PDF")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func startScan() {
        if VNDocumentCameraViewController.isSupported {
            showScanner = true
        } else {
            errorMessage = "This iPhone can't scan documents with the camera. Choose a photo or import a PDF instead."
        }
    }

    private func presentScannedImages() {
        guard !scannedImages.isEmpty else { return }
        let images = scannedImages
        scannedImages = []
        present(.images(images))
    }

    /// Waits for the picker or camera to finish dismissing before showing the review sheet.
    private func present(_ source: ScanSource) {
        Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            scanRequest = ScanRequest(source: source)
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let copy = try FileLoader.copyToTemporary(url)
                present(.file(copy))
            } catch {
                errorMessage = "That file couldn't be opened. Choose a PDF or a photo."
            }
        case .failure:
            errorMessage = "That file couldn't be opened. Choose a PDF or a photo."
        }
    }
}

struct LetterRow: View {
    let letter: Letter

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: letter.kind.symbol)
                .font(.title3)
                .foregroundStyle(iconColor)
                .frame(minWidth: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(letter.displaySender)
                    .font(.headline)
                    .lineLimit(2)
                let detail = letter.action.isEmpty ? letter.summary : letter.action
                if !detail.isEmpty {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                statusLine
                    .font(.footnote)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var statusLine: some View {
        HStack(spacing: 8) {
            if letter.isDone {
                Label("Done", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if !letter.needsAction {
                Text("No action needed")
                    .foregroundStyle(.secondary)
            } else if let due = letter.dueDate {
                Text(DueText.relative(due))
                    .foregroundStyle(isOverdue(due) ? Color.red : Color.secondary)
                    .fontWeight(isOverdue(due) ? .semibold : .regular)
            }
            if let amount = letter.formattedAmount {
                Text(amount)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func isOverdue(_ due: Date) -> Bool {
        LetterGrouping.bucket(for: due, now: Date()) == .overdue
    }

    private var iconColor: Color {
        if letter.isFiled { return .secondary }
        if let due = letter.dueDate, isOverdue(due) { return .red }
        return .accentColor
    }
}
