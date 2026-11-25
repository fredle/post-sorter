import SwiftData
import SwiftUI
import UIKit
import UserNotifications

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage(SettingsKeys.defaultDaysBefore) private var defaultDaysBefore = AppSettings.fallbackDaysBefore
    @AppStorage(SettingsKeys.reminderMinutes) private var reminderMinutes = AppSettings.fallbackReminderMinutes
    @AppStorage(SettingsKeys.lockEnabled) private var lockEnabled = false

    @Query private var letters: [Letter]
    @Query private var knownSenders: [KnownSender]

    @State private var notificationsDenied = false
    @State private var confirmForget = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $defaultDaysBefore, in: 0...30) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Remind me")
                            Text(ReminderText.daysBefore(defaultDaysBefore))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    DatePicker("Reminder time", selection: reminderTime, displayedComponents: .hourAndMinute)
                    if notificationsDenied {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Notifications are turned off for Post Sorter, so reminders can't appear.", systemImage: "bell.slash")
                                .foregroundStyle(.orange)
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    openURL(url)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Reminders")
                } footer: {
                    Text("New letters use this number of days. You can change it for each letter when you check its details.")
                }

                Section {
                    Toggle("Lock with \(BiometricAuth.lockName)", isOn: lockBinding)
                        .disabled(!BiometricAuth.canLock && !lockEnabled)
                } header: {
                    Text("Privacy")
                } footer: {
                    if BiometricAuth.canLock || lockEnabled {
                        Text("Post Sorter asks for \(BiometricAuth.lockName) each time you open it.")
                    } else {
                        Text("Set a passcode on this iPhone to lock Post Sorter.")
                    }
                }

                Section {
                    Label {
                        Text(OnDeviceModel.isAvailable
                             ? "Apple Intelligence reads your letters on this iPhone."
                             : "Post Sorter reads your letters with on-device text recognition. On iPhones with Apple Intelligence turned on, it also uses Apple's on-device model.")
                    } icon: {
                        Image(systemName: OnDeviceModel.isAvailable ? "sparkles" : "text.viewfinder")
                    }
                    Label("Letters, pages and reminders are stored only on this iPhone. Post Sorter only goes online if you send the developer a feedback note.", systemImage: "lock.shield")
                } header: {
                    Text("Reading letters")
                }

                Section {
                    Button("Forget remembered senders", role: .destructive) {
                        confirmForget = true
                    }
                    .disabled(knownSenders.isEmpty)
                } footer: {
                    Text(knownSenders.isEmpty
                         ? "When you save a letter, Post Sorter remembers its sender and type for next time."
                         : "\(knownSenders.count) remembered \(knownSenders.count == 1 ? "sender" : "senders"). Letters from them get their type filled in.")
                }

                Section {
                    FeedbackButton()
                } footer: {
                    Text("Sends the developer a short note. Only the note and the app version are sent, never your letters, name or email.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Forget remembered senders?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Forget senders", role: .destructive) {
                    for sender in knownSenders { context.delete(sender) }
                    try? context.save()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your letters stay. New letters will no longer get their type from earlier ones.")
            }
            .onChange(of: reminderMinutes) { _, _ in
                ReminderScheduler.rescheduleAll(letters.filter { !$0.isFiled })
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refreshNotificationStatus() }
            }
            .task {
                refreshNotificationStatus()
            }
        }
    }

    private var reminderTime: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: reminderMinutes / 60, minute: reminderMinutes % 60, second: 0, of: Date()) ?? Date()
            },
            set: { newValue in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                reminderMinutes = (parts.hour ?? 9) * 60 + (parts.minute ?? 0)
            }
        )
    }

    private var lockBinding: Binding<Bool> {
        Binding(
            get: { lockEnabled },
            set: { newValue in
                if newValue {
                    Task {
                        if await BiometricAuth.authenticate(reason: "Confirm it's you to turn on the lock.") {
                            lockEnabled = true
                        }
                    }
                } else {
                    lockEnabled = false
                }
            }
        )
    }

    private func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let denied = settings.authorizationStatus == .denied
            DispatchQueue.main.async {
                notificationsDenied = denied
            }
        }
    }
}
