import AppKit
import Foundation

enum AppLifecycleEvent: Equatable, Sendable {
    case launched
    case willSleep
    case didWake
    case systemClockChanged
    case systemTimeZoneChanged
    case lowPowerModeChanged(isEnabled: Bool)
    case userSessionBecameInactive
    case userSessionBecameActive
    case willTerminate
}

@MainActor
final class AppLifecycleEventSource {
    let events: AsyncStream<AppLifecycleEvent>

    private let continuation: AsyncStream<AppLifecycleEvent>.Continuation
    private var defaultCenterTokens: [NSObjectProtocol] = []
    private var workspaceCenterTokens: [NSObjectProtocol] = []
    private var isClosed = false

    init(
        defaultCenter: NotificationCenter = .default,
        workspace: NSWorkspace = .shared,
        processInfo: ProcessInfo = .processInfo
    ) {
        let pair = AsyncStream.makeStream(
            of: AppLifecycleEvent.self,
            bufferingPolicy: .bufferingNewest(32)
        )
        events = pair.stream
        let capturedContinuation = pair.continuation
        self.continuation = capturedContinuation

        defaultCenterTokens = [
            defaultCenter.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { _ in
                capturedContinuation.yield(.systemClockChanged)
            },
            defaultCenter.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { _ in
                capturedContinuation.yield(.systemTimeZoneChanged)
            },
            defaultCenter.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
                capturedContinuation.yield(.lowPowerModeChanged(isEnabled: processInfo.isLowPowerModeEnabled))
            },
            defaultCenter.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
                capturedContinuation.yield(.willTerminate)
                capturedContinuation.finish()
            },
        ]

        let workspaceCenter = workspace.notificationCenter
        workspaceCenterTokens = [
            workspaceCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: workspace, queue: .main) { _ in
                capturedContinuation.yield(.willSleep)
            },
            workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: workspace, queue: .main) { _ in
                capturedContinuation.yield(.didWake)
            },
            workspaceCenter.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: workspace, queue: .main) { _ in
                capturedContinuation.yield(.userSessionBecameInactive)
            },
            workspaceCenter.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: workspace, queue: .main) { _ in
                capturedContinuation.yield(.userSessionBecameActive)
            },
        ]
        for event in Self.initialEvents(isLowPowerModeEnabled: processInfo.isLowPowerModeEnabled) {
            capturedContinuation.yield(event)
        }
    }

    nonisolated static func initialEvents(isLowPowerModeEnabled: Bool) -> [AppLifecycleEvent] {
        [
            .lowPowerModeChanged(isEnabled: isLowPowerModeEnabled),
            .launched,
        ]
    }

    func close(defaultCenter: NotificationCenter = .default, workspace: NSWorkspace = .shared) {
        guard !isClosed else { return }
        isClosed = true
        defaultCenterTokens.forEach(defaultCenter.removeObserver)
        workspaceCenterTokens.forEach(workspace.notificationCenter.removeObserver)
        defaultCenterTokens.removeAll()
        workspaceCenterTokens.removeAll()
        continuation.finish()
    }
}
