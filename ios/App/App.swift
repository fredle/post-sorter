import SwiftData
import SwiftUI
import UIKit
import UserNotifications

@main
struct PostSorterApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            if DemoMode.isOn {
                DemoRootView()
            } else {
                RootView()
            }
        }
        .modelContainer(for: [Letter.self, KnownSender.self])
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// Show reminders even while the app is open.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}

/// Hosts the home screen and the optional Face ID lock.
struct RootView: View {
    @AppStorage(SettingsKeys.lockEnabled) private var lockEnabled = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var isLocked = true
    @State private var isAuthenticating = false

    var body: some View {
        ZStack {
            HomeView()
            if lockEnabled && isLocked {
                LockScreen(isAuthenticating: isAuthenticating, unlock: unlock)
                    .transition(.opacity)
            }
        }
        .task {
            if lockEnabled && isLocked { unlock() }
        }
        .onChange(of: scenePhase) { _, phase in
            guard lockEnabled else { return }
            if phase == .background {
                isLocked = true
            } else if phase == .active && isLocked {
                unlock()
            }
        }
        .onChange(of: lockEnabled) { _, enabled in
            // Turning the lock on from Settings shouldn't lock the screen straight away.
            if enabled { isLocked = false }
        }
    }

    private func unlock() {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        Task {
            let success = await BiometricAuth.authenticate(reason: "Unlock Post Sorter to see your letters.")
            isAuthenticating = false
            if success {
                withAnimation { isLocked = false }
            }
        }
    }
}

struct LockScreen: View {
    let isAuthenticating: Bool
    let unlock: () -> Void

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "lock.fill")
                    .font(.largeTitle)
                    .imageScale(.large)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Post Sorter is locked")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Button(action: unlock) {
                    Label("Unlock with \(BiometricAuth.lockName)", systemImage: "faceid")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isAuthenticating)
            }
            .padding()
        }
    }
}
