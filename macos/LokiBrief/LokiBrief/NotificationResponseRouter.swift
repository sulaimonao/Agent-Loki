import Foundation
import UserNotifications

struct NotificationRouteTicket: Equatable, Sendable {
    fileprivate let generation: UInt64
}

private final class NotificationRouteEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    func capture() -> NotificationRouteTicket {
        lock.lock()
        defer { lock.unlock() }
        return NotificationRouteTicket(generation: generation)
    }

    func advance() {
        lock.lock()
        generation &+= 1
        lock.unlock()
    }

    func accepts(_ ticket: NotificationRouteTicket) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == ticket.generation
    }
}

actor NotificationRouteBuffer {
    typealias Handler = @MainActor @Sendable (NotificationRoute) -> Void

    nonisolated private let epoch = NotificationRouteEpoch()
    private var handler: Handler?
    private var queued: [(route: NotificationRoute, ticket: NotificationRouteTicket)] = []
    private var acceptingRoutes = true

    nonisolated func captureTicket() -> NotificationRouteTicket { epoch.capture() }

    func connect(_ handler: @escaping Handler) async {
        self.handler = handler
        let pending = queued
        queued.removeAll()
        for pendingRoute in pending {
            await deliver(pendingRoute.route, ticket: pendingRoute.ticket, handler: handler)
        }
    }

    func disconnect() {
        handler = nil
    }

    func enqueue(_ route: NotificationRoute) async {
        await enqueue(route, ticket: captureTicket())
    }

    func enqueue(_ route: NotificationRoute, ticket: NotificationRouteTicket) async {
        guard acceptingRoutes, epoch.accepts(ticket) else { return }
        if let handler {
            await deliver(route, ticket: ticket, handler: handler)
            return
        }
        guard !queued.contains(where: { $0.route.notificationIdentifier == route.notificationIdentifier }) else { return }
        if queued.count == LokiNotificationContract.maximumQueuedRoutes { queued.removeFirst() }
        queued.append((route, ticket))
    }

    func invalidate() {
        epoch.advance()
        acceptingRoutes = false
        queued.removeAll()
    }

    func resume() {
        epoch.advance()
        acceptingRoutes = true
        queued.removeAll()
    }

    func pendingRoutesForTesting() -> [NotificationRoute] { queued.map(\.route) }

    private func deliver(
        _ route: NotificationRoute,
        ticket: NotificationRouteTicket,
        handler: @escaping Handler
    ) async {
        let epoch = self.epoch
        await MainActor.run {
            guard epoch.accepts(ticket) else { return }
            handler(route)
        }
    }
}

actor UpdateRouteBuffer {
    typealias Handler = @MainActor @Sendable (UpdateRoute) -> Void

    private var handler: Handler?
    private var queuedRoute: UpdateRoute?

    func connect(_ handler: @escaping Handler) async {
        self.handler = handler
        if let queuedRoute {
            self.queuedRoute = nil
            await MainActor.run { handler(queuedRoute) }
        }
    }

    func enqueue(_ route: UpdateRoute) async {
        if let handler {
            await MainActor.run { handler(route) }
        } else {
            queuedRoute = route
        }
    }

    func disconnect() {
        handler = nil
    }

    func pendingRouteForTesting() -> UpdateRoute? { queuedRoute }
}

enum UpdateNotificationRouteParser {
    static func parse(
        actionIdentifier: String,
        categoryIdentifier: String,
        notificationIdentifier: String,
        userInfo: [AnyHashable: Any]
    ) -> UpdateRoute? {
        guard actionIdentifier == UNNotificationDefaultActionIdentifier,
              categoryIdentifier == UpdateRoute.availabilityNotificationCategoryIdentifier,
              userInfo.isEmpty
        else { return nil }
        return UpdateRoute.notification(identifier: notificationIdentifier)
    }
}

enum NotificationRouteParser {
    static func parse(
        actionIdentifier: String,
        categoryIdentifier: String,
        notificationIdentifier: String,
        userInfo: [AnyHashable: Any]
    ) -> NotificationRoute? {
        guard actionIdentifier == UNNotificationDefaultActionIdentifier,
              categoryIdentifier == LokiNotificationContract.categoryIdentifier,
              LokiNotificationContract.validNotificationIdentifier(notificationIdentifier),
              let payloadVersion = userInfo[LokiNotificationContract.UserInfoKey.version] as? String,
              LokiNotificationContract.supportedPayloadVersions.contains(payloadVersion),
              let briefID = userInfo[LokiNotificationContract.UserInfoKey.briefID] as? String,
              LokiNotificationContract.validBriefIdentifier(briefID)
        else { return nil }
        return NotificationRoute(notificationIdentifier: notificationIdentifier, briefID: briefID)
    }
}

/// Retain one instance from the application delegate and install it before the
/// application finishes launching. The route buffer safely accepts a response
/// before AppModel and the SwiftUI window-opening bridge are connected.
final class NotificationResponseRouter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    let buffer: NotificationRouteBuffer
    let updateBuffer: UpdateRouteBuffer
    private let traceSink: NotificationTraceSink

    init(
        buffer: NotificationRouteBuffer = NotificationRouteBuffer(),
        updateBuffer: UpdateRouteBuffer = UpdateRouteBuffer(),
        traceSink: @escaping NotificationTraceSink = { _ in }
    ) {
        self.buffer = buffer
        self.updateBuffer = updateBuffer
        self.traceSink = traceSink
    }

    func install(on center: UNUserNotificationCenter = .current()) {
        center.delegate = self
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let request = response.notification.request
        if let updateRoute = UpdateNotificationRouteParser.parse(
            actionIdentifier: response.actionIdentifier,
            categoryIdentifier: request.content.categoryIdentifier,
            notificationIdentifier: request.identifier,
            userInfo: request.content.userInfo
        ) {
            Task {
                await updateBuffer.enqueue(updateRoute)
                traceSink(.init(
                    event: "notification_response",
                    traceID: UUID().uuidString.lowercased(),
                    status: .success,
                    reasonCode: "update_route_queued",
                    notificationIdentifier: request.identifier
                ))
                completionHandler()
            }
            return
        }
        let route = NotificationRouteParser.parse(
            actionIdentifier: response.actionIdentifier,
            categoryIdentifier: request.content.categoryIdentifier,
            notificationIdentifier: request.identifier,
            userInfo: request.content.userInfo
        )
        guard let route else {
            traceSink(.init(
                event: "notification_response",
                traceID: UUID().uuidString.lowercased(),
                status: .skipped,
                reasonCode: response.actionIdentifier == UNNotificationDismissActionIdentifier
                    ? "notification_dismissed"
                    : "notification_response_rejected"
            ))
            completionHandler()
            return
        }

        let ticket = buffer.captureTicket()
        Task {
            await buffer.enqueue(route, ticket: ticket)
            traceSink(.init(
                event: "notification_response",
                traceID: UUID().uuidString.lowercased(),
                status: .success,
                reasonCode: "brief_route_queued",
                notificationIdentifier: route.notificationIdentifier
            ))
            completionHandler()
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let category = notification.request.content.categoryIdentifier
        guard category == LokiNotificationContract.categoryIdentifier
                || category == UpdateRoute.availabilityNotificationCategoryIdentifier
        else {
            completionHandler([])
            return
        }
        completionHandler([.banner, .list])
    }
}
