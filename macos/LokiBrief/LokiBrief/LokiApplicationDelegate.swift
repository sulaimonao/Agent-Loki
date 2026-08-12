import AppKit
import Foundation

enum LokiShutdownResult: String, Equatable, Sendable {
    case completed
    case timedOut = "timed_out"
}

private actor LokiShutdownRace {
    private var result: LokiShutdownResult?
    private var continuation: CheckedContinuation<LokiShutdownResult, Never>?

    func wait() async -> LokiShutdownResult {
        if let result { return result }
        return await withCheckedContinuation { continuation = $0 }
    }

    func resolve(_ candidate: LokiShutdownResult) {
        guard result == nil else { return }
        result = candidate
        continuation?.resume(returning: candidate)
        continuation = nil
    }
}

@MainActor
final class LokiApplicationDelegate: NSObject, NSApplicationDelegate {
    let notificationRouter = NotificationResponseRouter()
    private(set) var lifecycleSource: AppLifecycleEventSource?
    private var shutdownHandler: (@Sendable () async -> Void)?
    private var terminationInProgress = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        notificationRouter.install()
        lifecycleSource = AppLifecycleEventSource()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if lifecycleSource == nil { lifecycleSource = AppLifecycleEventSource() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let reply = Self.terminationReply(
            shutdownHandlerInstalled: shutdownHandler != nil,
            terminationInProgress: terminationInProgress
        )
        guard !terminationInProgress, let shutdownHandler else { return reply }
        terminationInProgress = true
        Task { @MainActor in
            let clock = ContinuousClock()
            let startedAt = clock.now
            let result = await Self.performBoundedShutdown(shutdownHandler)
            let duration = startedAt.duration(to: clock.now)
            ScheduledBriefingProductionTraceLogger.emit(Self.shutdownTraceEvent(
                result: result,
                durationMilliseconds: Self.milliseconds(duration)
            ))
            lifecycleSource?.close()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return reply
    }

    nonisolated static func performBoundedShutdown(
        timeout: Duration = .seconds(3),
        _ handler: @escaping @Sendable () async -> Void
    ) async -> LokiShutdownResult {
        let race = LokiShutdownRace()
        let cleanupTask = Task {
            await handler()
            await race.resolve(.completed)
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
                await race.resolve(.timedOut)
            } catch is CancellationError {
                return
            } catch {
                await race.resolve(.timedOut)
            }
        }
        let result = await race.wait()
        switch result {
        case .completed:
            timeoutTask.cancel()
        case .timedOut:
            cleanupTask.cancel()
        }
        return result
    }

    static func shutdownTraceEvent(
        result: LokiShutdownResult,
        durationMilliseconds: Int,
        timestamp: Date = .now,
        trace: ScheduledBriefingTraceContext = .init()
    ) -> ScheduledBriefingTraceEvent {
        .init(
            ts: timestamp,
            event: .applicationShutdown,
            traceID: trace.traceID,
            spanID: trace.spanID,
            parentSpanID: trace.parentSpanID,
            component: "application_lifecycle",
            status: result == .completed ? .success : .degraded,
            reasonCode: result == .completed ? "application_shutdown_completed" : "application_shutdown_timed_out",
            durationMilliseconds: max(0, durationMilliseconds),
            metadata: .init([
                (.shutdownResult, result.rawValue),
                (.timeoutMilliseconds, "3000"),
            ])
        )
    }

    static func terminationReply(shutdownHandlerInstalled: Bool, terminationInProgress: Bool) -> NSApplication.TerminateReply {
        if terminationInProgress { return .terminateLater }
        return shutdownHandlerInstalled ? .terminateLater : .terminateNow
    }

    private nonisolated static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        let seconds = components.seconds.multipliedReportingOverflow(by: 1_000)
        let fractional = components.attoseconds / 1_000_000_000_000_000
        guard !seconds.overflow else { return Int.max }
        return max(0, Int(clamping: seconds.partialValue.addingReportingOverflow(fractional).partialValue))
    }

    func installShutdownHandler(_ handler: @escaping @Sendable () async -> Void) {
        shutdownHandler = handler
    }
}
