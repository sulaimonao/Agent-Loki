import AppKit
import Combine
import SwiftUI

private enum LokiMainWindowRoute: String, Codable, Hashable {
    case primary
}

@main
struct LokiBriefApp: App {
    @NSApplicationDelegateAdaptor(LokiApplicationDelegate.self) private var appDelegate
    @StateObject private var model: AppModel
    @StateObject private var updates: SecureUpdateController
    private let signedSmokeCoordinator:
        P8FSignedSmokeCoordinator?

    init() {
        let bootstrap: P8FSignedSmokeBootstrap?
        do {
            bootstrap =
                try P8FSignedSmokeBootstrap
                    .resolveIfRequested()
        } catch let failure as P8FSignedSmokeAdmissionFailure {
            fatalError(failure.rawValue)
        } catch let failure as P8FSignedSmokeCoordinatorFailure {
            fatalError(failure.rawValue)
        } catch {
            fatalError(
                P8FSignedSmokeCoordinatorFailure
                    .prerequisiteMissing.rawValue
            )
        }
        let model: AppModel
        if let bootstrap {
            let providerEvidenceRun:
                P8FProviderRequestEvidenceRun
            do {
                providerEvidenceRun = try P8FProviderRequestCorrelationRecorder
                    .shared
                    .activate(
                        processIdentifier:
                            ProcessInfo.processInfo
                                .processIdentifier,
                        admittedExecutableSHA256:
                            bootstrap.applicationIdentity
                                .executableSHA256,
                        runIdentifier:
                            bootstrap.admission.controlPlan
                                .runIdentifier
                    )
                model =
                    try AppModel.makeAdmittedSignedSmoke(
                        bootstrap.admission
                    )
            } catch {
                fatalError(
                    P8FSignedSmokeCoordinatorFailure
                        .prerequisiteMissing.rawValue
                )
            }
            signedSmokeCoordinator =
                P8FSignedSmokeCoordinator(
                    bootstrap: bootstrap,
                    providerEvidenceRun: providerEvidenceRun
                )
        } else {
            model = AppModel.live()
            signedSmokeCoordinator = nil
        }
        _model = StateObject(wrappedValue: model)
        if bootstrap != nil {
            _updates = StateObject(
                wrappedValue: SecureUpdateController(
                    model: model,
                    availabilityNotifier:
                        P8FSignedSmokeInertUpdateAvailabilityNotifier(),
                    inertForSignedSmoke: true
                )
            )
        } else {
            _updates = StateObject(
                wrappedValue: SecureUpdateController(model: model)
            )
        }
    }

    var body: some Scene {
        WindowGroup("Loki Brief", id: "main", for: LokiMainWindowRoute.self) { _ in
            LokiRootScene(
                model: model,
                updates: updates,
                appDelegate: appDelegate,
                signedSmokeCoordinator:
                    signedSmokeCoordinator
            )
        } defaultValue: {
            .primary
        }
            .defaultSize(width: 1080, height: 720)
            .commands { LokiCommands(model: model, updates: updates) }
        MenuBarExtra("Loki Brief", systemImage: "sun.horizon.fill") {
            MenuBarContent()
                .environmentObject(model)
                .environmentObject(updates)
        }
    }
}

private struct LokiRootScene: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: AppModel
    @ObservedObject var updates: SecureUpdateController
    let appDelegate: LokiApplicationDelegate
    let signedSmokeCoordinator:
        P8FSignedSmokeCoordinator?

    var body: some View {
        RootView()
            .environmentObject(model)
            .environmentObject(updates)
            .task {
                appDelegate.installShutdownHandler { [weak model, weak updates] in
                    await updates?.shutdownForApplicationTermination()
                    await model?.shutdownForApplicationTermination()
                }
                if let signedSmokeCoordinator {
                    _ = await signedSmokeCoordinator.execute(
                        model: model
                    )
                    NSApp.terminate(nil)
                    return
                }
                await appDelegate.notificationRouter.updateBuffer.connect { route in
                    updates.handle(route)
                    openWindow(id: "main", value: LokiMainWindowRoute.primary)
                    NSApp.activate()
                }
                await model.p5Controller?.activate(
                    lifecycle: appDelegate.lifecycleSource,
                    notificationBuffer: appDelegate.notificationRouter.buffer,
                    openMainWindow: { openWindow(id: "main", value: LokiMainWindowRoute.primary) }
                )
            }
            .task {
                guard signedSmokeCoordinator == nil else {
                    return
                }
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(30))
                    } catch {
                        return
                    }
                    model.synchronizeCurrentDayPresentation()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemClockDidChange)) { _ in
                if signedSmokeCoordinator == nil {
                    model.synchronizeCurrentDayPresentation()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
                if signedSmokeCoordinator == nil {
                    model.synchronizeCurrentDayPresentation()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                if signedSmokeCoordinator == nil {
                    model.synchronizeCurrentDayPresentation()
                }
            }
    }
}

struct LokiCommands: Commands {
    @ObservedObject var model: AppModel
    @ObservedObject var updates: SecureUpdateController
    var body: some Commands {
        // The keyed `.primary` route is the one logical main window. Remove
        // SwiftUI's default New Window command so Command-N/File cannot create
        // a second instance outside that route.
        CommandGroup(replacing: .newItem) { }
        CommandMenu("Brief") {
            Button("Refresh All Enabled Feeds") { model.refreshAllFeeds() }.keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Cancel Refresh") { model.cancelRefresh() }.keyboardShortcut(".", modifiers: [.command])
            Divider()
            ForEach(NavigationDestination.allCases) { destination in Button(destination.rawValue) { model.navigate(to: destination) } }
        }
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updates.handle(.check(from: .appMenu)) }
                .disabled(!updates.canCheckForUpdates)
        }
    }
}

struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var updates: SecureUpdateController
    private func show(_ destination: NavigationDestination) { model.navigate(to: destination); openWindow(id: "main", value: LokiMainWindowRoute.primary); NSApp.activate() }
    var body: some View {
        Button("Open Loki Brief") { show(.today) }
        if model.isPresentingHistoricalBrief {
            Text("Historical brief: \(model.brief.resolvedBriefingDay.formatted(.abbreviated)) · \(model.brief.itemCount) items")
        } else {
            Text("Today’s brief: \(model.brief.itemCount) items · \(LokiBriefPresentation.label(for: model.refreshState.rawValue))")
        }
        if let delivery = model.p5Controller {
            Text("Next: \(nextOccurrenceLabel(delivery) ?? "not scheduled")")
            Text("Delivery: \(LokiBriefPresentation.label(for: delivery.currentRunState.rawValue))")
            Button("Run Brief Now") { delivery.generateBriefNow() }
            Button("Cancel Current Run") { Task { await delivery.cancelCurrentRun() } }.disabled(!delivery.isBusy)
        }
        Button("Refresh All Enabled Feeds") { model.refreshAllFeeds(); show(.today) }
        Button("Cancel Refresh") { model.cancelRefresh() }
        Button("Check for Updates…") { updates.handle(.check(from: .menuBar)) }
            .disabled(!updates.canCheckForUpdates)
        Divider()
        Button("Sources") { show(.sources) }
        Button("Vault") { show(.vault) }
        Button("Local Models") { show(.models) }
        Button("Open Today") { show(.today) }
        Button("Open Delivery Settings") { show(.delivery) }
        Button("Settings") { show(.settings) }
        Divider()
        Button("Quit Loki Brief") { NSApp.terminate(nil) }.keyboardShortcut("q")
            .onAppear { model.synchronizeCurrentDayPresentation() }
    }

    private func nextOccurrenceLabel(_ delivery: P5DeliveryController) -> String? {
        guard let occurrence = delivery.schedulerSnapshot.nextOccurrence else { return nil }
        return "\(occurrence.briefingDay.formatted(.abbreviated)) · \(occurrence.resolvedExecutionDate.formatted(date: .omitted, time: .shortened))"
    }
}
