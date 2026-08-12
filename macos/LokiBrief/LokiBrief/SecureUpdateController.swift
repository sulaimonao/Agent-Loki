import AppKit
import Combine
import Foundation
import Sparkle
import UserNotifications

enum UpdateAvailabilityNotificationResult: String, Equatable, Sendable {
    case posted
    case authorizationUnavailable = "authorization_unavailable"
    case manualCheckSuppressed = "manual_check_suppressed"
    case failed
}

protocol UpdateAvailabilityNotifying: Sendable {
    func postAvailabilityNotificationIfAuthorized() async -> UpdateAvailabilityNotificationResult
}

struct SystemUpdateAvailabilityNotifier: UpdateAvailabilityNotifying, @unchecked Sendable {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func postAvailabilityNotificationIfAuthorized() async -> UpdateAvailabilityNotificationResult {
        let settings = await withCheckedContinuation { continuation in
            center.getNotificationSettings { continuation.resume(returning: $0) }
        }
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            break
        case .notDetermined, .denied:
            return .authorizationUnavailable
        @unknown default:
            return .authorizationUnavailable
        }

        let content = UNMutableNotificationContent()
        content.title = "Loki Brief update available"
        content.body = "Open Loki Brief to review the signed update."
        content.categoryIdentifier = UpdateRoute.availabilityNotificationCategoryIdentifier
        content.userInfo = [:]
        let request = UNNotificationRequest(
            identifier: UpdateRoute.availabilityNotificationIdentifier,
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
            return .posted
        } catch {
            return .failed
        }
    }
}

struct P8FSignedSmokeInertUpdateAvailabilityNotifier:
    UpdateAvailabilityNotifying
{
    func postAvailabilityNotificationIfAuthorized()
        async -> UpdateAvailabilityNotificationResult
    {
        .authorizationUnavailable
    }
}

private enum SecureUpdatePreferenceKey {
    static let channel = "LokiBrief.UpdateChannel"
    static let retainedCandidateChannel = "LokiBrief.RetainedUpdateChannel"
    static let pendingReceipt = "LokiBrief.PendingUpdateReceipt"
}

struct SecureUpdateProviderFailureClassification: Equatable, Sendable {
    let code: UpdateFailureCode
    let reasonCode: String
    let consumerMessage: String
}

enum SecureUpdateProviderErrorClassifier {
    static let sparkleErrorDomain = SUSparkleErrorDomain

    static func classify(_ error: Error) -> SecureUpdateProviderFailureClassification {
        if let failure = error as? UpdateFailure {
            return classification(for: failure)
        }
        let chain = errorChain(error)
        if let encodedFailure = chain.first(where: { $0.domain == UpdateFailure.errorDomain }),
           let rawCode = encodedFailure.userInfo[UpdateFailure.failureCodeUserInfoKey] as? String,
           let code = UpdateFailureCode(rawValue: rawCode) {
            let failure = UpdateFailure(
                code: code,
                isRecoverable: encodedFailure.userInfo[UpdateFailure.recoverableUserInfoKey] as? Bool ?? false,
                consumerMessage: encodedFailure.localizedDescription
            )
            return classification(for: failure)
        }
        let offlineCodes: Set<Int> = [
            NSURLErrorNotConnectedToInternet,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorTimedOut,
            NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost,
            NSURLErrorDNSLookupFailed,
        ]
        if chain.contains(where: { $0.domain == NSURLErrorDomain && offlineCodes.contains($0.code) }) {
            return .init(
                code: .offline,
                reasonCode: "update_provider_offline",
                consumerMessage: "The update service is offline. Loki Brief remains unchanged."
            )
        }

        let sparkleCodes = Set(chain.filter { $0.domain == sparkleErrorDomain }.map(\.code))
        if !sparkleCodes.isDisjoint(with: [3_001, 3_002, 4_009]) {
            return .init(
                code: .invalidSignature,
                reasonCode: "update_signature_or_archive_rejected",
                consumerMessage: "The signed update or archive failed validation and was rejected."
            )
        }
        if sparkleCodes.contains(4_006) {
            return .init(
                code: .olderVersion,
                reasonCode: "update_older_version_rejected",
                consumerMessage: "The offered update is not newer than this installation and was rejected."
            )
        }
        if sparkleCodes.contains(4_008) {
            return .init(
                code: .installationBlocked,
                reasonCode: "update_install_authorization_deferred",
                consumerMessage: "Update authorization was postponed. Local stores were recovered; retry when you are ready."
            )
        }
        if sparkleCodes.contains(4_004) {
            return .init(
                code: .relaunchFailed,
                reasonCode: "update_relaunch_failed",
                consumerMessage: "The update could not relaunch Loki Brief. The current installation remains available."
            )
        }
        if sparkleCodes.contains(2_001) {
            return .init(
                code: .downloadFailed,
                reasonCode: "update_download_failed",
                consumerMessage: "The signed update could not be downloaded."
            )
        }
        if !sparkleCodes.isDisjoint(with: [3, 4, 1_000, 1_002]) {
            return .init(
                code: .feedUnavailable,
                reasonCode: "update_feed_unavailable",
                consumerMessage: "The signed update feed is unavailable or invalid."
            )
        }
        return .init(
            code: .providerFailure,
            reasonCode: "update_provider_failure",
            consumerMessage: "The update was not installed. Loki Brief remains on the current version."
        )
    }

    private static func classification(for failure: UpdateFailure) -> SecureUpdateProviderFailureClassification {
        .init(
            code: failure.code,
            reasonCode: "update_\(failure.code.rawValue)",
            consumerMessage: failure.consumerMessage
        )
    }

    private static func errorChain(_ error: Error, depth: Int = 0) -> [NSError] {
        let nsError = error as NSError
        guard depth < 4,
              let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error,
              underlying as NSError !== nsError
        else { return [nsError] }
        return [nsError] + errorChain(underlying, depth: depth + 1)
    }
}

enum SecureUpdateNoUpdateClassification: Equatable, Sendable {
    case upToDate
    case olderFeed
    case incompatibleSystem
    case unknown
}

enum SecureUpdateNoUpdateClassifier {
    // SPUNoUpdateFoundReason is sequential in the pinned Sparkle 2.9.4 API.
    private static let onLatestVersion = 1
    private static let onNewerThanLatestVersion = 2
    private static let systemIsTooOld = 3
    private static let systemIsTooNew = 4
    private static let hardwareDoesNotSupportARM64 = 5

    static func classify(_ error: Error) -> SecureUpdateNoUpdateClassification {
        let nsError = error as NSError
        guard let reason = nsError.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber else {
            return .unknown
        }
        switch reason.intValue {
        case onLatestVersion: return .upToDate
        case onNewerThanLatestVersion: return .olderFeed
        case systemIsTooOld, systemIsTooNew, hardwareDoesNotSupportARM64: return .incompatibleSystem
        default: return .unknown
        }
    }
}

struct SecureUpdateOperationGate: Equatable, Sendable {
    private(set) var recoveryInProgress = false
    private(set) var restartRequired = false
    private(set) var installPreparationID: UUID?

    mutating func beginRecovery() -> Bool {
        guard !recoveryInProgress else { return false }
        recoveryInProgress = true
        return true
    }

    mutating func finishRecovery() {
        recoveryInProgress = false
    }

    func allowsCheck(providerCanCheck: Bool) -> Bool {
        !recoveryInProgress && !restartRequired && providerCanCheck
    }

    mutating func requireRestart() {
        restartRequired = true
    }

    mutating func beginInstallPreparation() -> UUID {
        let identifier = UUID()
        installPreparationID = identifier
        return identifier
    }

    func isCurrentInstallPreparation(_ identifier: UUID) -> Bool {
        installPreparationID == identifier
    }

    mutating func finishInstallPreparation(_ identifier: UUID) {
        if installPreparationID == identifier { installPreparationID = nil }
    }

    mutating func invalidateInstallPreparation() {
        installPreparationID = nil
    }
}

enum SecureUpdateChoiceDisposition: Equatable, Sendable {
    case proceed
    case clearAvailability(reasonCode: String)
    case retainDownloaded(reasonCode: String)
    case retainInstalling(reasonCode: String)
}

enum SecureUpdateChoiceClassifier {
    static func classify(
        choice: SPUUserUpdateChoice,
        stage: SPUUserUpdateStage
    ) -> SecureUpdateChoiceDisposition {
        switch choice {
        case .install:
            return .proceed
        case .skip:
            return .clearAvailability(reasonCode: "update_user_skipped_version")
        case .dismiss:
            switch stage {
            case .notDownloaded:
                return .clearAvailability(reasonCode: "update_user_dismissed_before_download")
            case .downloaded:
                return .retainDownloaded(reasonCode: "update_download_retained_after_dismiss")
            case .installing:
                return .retainInstalling(reasonCode: "update_install_retained_after_dismiss")
            @unknown default:
                return .clearAvailability(reasonCode: "update_user_choice_stage_unknown")
            }
        @unknown default:
            return .clearAvailability(reasonCode: "update_user_choice_unknown")
        }
    }
}

struct SecureUpdateReadinessTraceSink: ApplicationUpdateReadinessEventSinking {
    let logger: UpdateProductionTraceLogger

    init(logger: UpdateProductionTraceLogger = UpdateProductionTraceLogger()) {
        self.logger = logger
    }

    func record(_ event: ApplicationUpdateReadinessEvent) async {
        let status: UpdateTraceStatus = switch event.status {
        case .started: .started
        case .success: .success
        case .degraded: .degraded
        case .failed: .failed
        case .skipped: .skipped
        }
        let route = event.event
            .lowercased()
            .replacingOccurrences(of: "application_update.", with: "readiness.")
        var metadata: [UpdateTraceMetadataKey: String] = [.route: route]
        if let blockerCount = event.metadata["blocker_count"] {
            metadata[.blockerCount] = blockerCount
        }
        logger.emit(UpdateTraceEvent(
            ts: event.timestamp,
            event: .installReadiness,
            context: UpdateTraceContext(
                traceID: event.traceID,
                spanID: event.spanID,
                parentSpanID: event.parentSpanID
            ),
            status: status,
            reasonCode: event.reasonCode,
            durationMS: event.durationMilliseconds,
            metadata: UpdateTraceMetadata(metadata)
        ))
    }
}

/// The application-facing secure update coordinator. Its published values use
/// provider-neutral domain types; Sparkle is confined to this boundary.
@MainActor
final class SecureUpdateController: NSObject, ObservableObject {
    @Published private(set) var state: UpdateState = .idle
    @Published private(set) var channel: UpdateChannel
    @Published private(set) var automaticChecksEnabled = false
    @Published private(set) var availability: UpdateAvailability?
    @Published private(set) var installReadiness: UpdateInstallReadiness = .ready
    @Published private(set) var statusMessage = "Updates are checked only when you ask."
    @Published private(set) var providerCanCheckForUpdates = false

    let currentVersion: UpdateVersion

    private let feedResolver: UpdateFeedResolver
    private let defaults: UserDefaults
    private let traceLogger: UpdateProductionTraceLogger
    private let readinessCoordinator: ApplicationUpdateReadinessCoordinator
    private let providerStarter: @MainActor (SPUUpdater) throws -> Void
    private let availabilityNotifier: any UpdateAvailabilityNotifying
    private let inertForSignedSmoke: Bool
    private var updaterController: SPUStandardUpdaterController!
    private var updaterStarted = false
    private var activeTrace = UpdateTraceContext()
    private var activeCheckTrigger: UpdateCheckTrigger = .manual
    private var updateLease: ApplicationUpdateLease?
    private var pendingInstallHandler: (() -> Void)?
    private var readinessTask: Task<Void, Never>?
    private var operationGate = SecureUpdateOperationGate()
    private var providerCanCheckObservation: AnyCancellable?

    var canCheckForUpdates: Bool {
        guard updaterStarted else { return false }
        return operationGate.allowsCheck(providerCanCheck: providerCanCheckForUpdates)
    }

    var configuredChannels: Set<UpdateChannel> {
        Set(UpdateChannel.allCases.filter { (try? feedResolver.resolve(channel: $0)) != nil })
    }

    var providerAllowedChannels: Set<String> {
        switch channel {
        case .stable: []
        case .beta: [UpdateChannel.beta.rawValue]
        case .internal: [UpdateChannel.internal.rawValue]
        }
    }

    let requestsFirstLaunchUpdateCheckPermission = false

    init(
        model: AppModel,
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard,
        traceLogger: UpdateProductionTraceLogger = UpdateProductionTraceLogger(),
        feedConfiguration: UpdateFeedConfiguration? = nil,
        availabilityNotifier: any UpdateAvailabilityNotifying = SystemUpdateAvailabilityNotifier(),
        readinessCoordinator: ApplicationUpdateReadinessCoordinator? = nil,
        providerStarter: @escaping @MainActor (SPUUpdater) throws -> Void = { try $0.start() },
        inertForSignedSmoke: Bool = false
    ) {
        self.defaults = defaults
        self.traceLogger = traceLogger
        self.providerStarter = providerStarter
        self.availabilityNotifier = availabilityNotifier
        self.inertForSignedSmoke = inertForSignedSmoke
        self.feedResolver = UpdateFeedResolver(
            configuration: feedConfiguration ?? Self.feedConfiguration(bundle: bundle)
        )
        let marketingVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let buildVersion = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        self.currentVersion = UpdateVersion(
            marketingVersion: marketingVersion,
            buildVersion: buildVersion
        )
        if inertForSignedSmoke {
            self.channel = .default
        } else {
            let storedChannel = defaults
                .string(forKey: SecureUpdatePreferenceKey.channel)
                .flatMap(UpdateChannel.init(rawValue:))
            let retainedChannel = defaults
                .string(
                    forKey:
                        SecureUpdatePreferenceKey
                            .retainedCandidateChannel
                )
                .flatMap(UpdateChannel.init(rawValue:))
            self.channel =
                retainedChannel ?? storedChannel ?? .default
        }
        self.readinessCoordinator = readinessCoordinator ?? ApplicationUpdateReadinessCoordinator(
                participants: [LokiApplicationUpdateParticipant(model: model)],
                eventSink: SecureUpdateReadinessTraceSink(logger: traceLogger)
        )
        super.init()

        guard !inertForSignedSmoke else {
            statusMessage =
                "Update authority is disabled for the signed smoke runner."
            return
        }
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        providerCanCheckObservation = updaterController.updater
            .publisher(for: \.canCheckForUpdates, options: [.initial, .new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                Task { @MainActor in self?.providerCanCheckForUpdates = value }
            }
        startProviderIfConfigured()
        restorePendingReceiptIfPresent()
    }

    func checkForUpdates() {
        guard !inertForSignedSmoke else { return }
        guard !operationGate.restartRequired else {
            statusMessage = "Restart Loki Brief before checking again because local store recovery was incomplete."
            return
        }
        guard !operationGate.recoveryInProgress else {
            statusMessage = "Wait for local stores to recover before checking again."
            traceLogger.emit(UpdateTraceEvent(
                event: .check,
                context: UpdateTraceContext(),
                status: .skipped,
                reasonCode: "update_check_blocked_recovery_in_progress"
            ))
            return
        }
        activeTrace = UpdateTraceContext()
        activeCheckTrigger = .manual
        guard resolveCurrentFeed() != nil else {
            setFailure(
                code: .feedUnavailable,
                message: "No secure HTTPS update feed is configured for the \(channel.rawValue) channel.",
                state: .feedUnavailable,
                event: .feedResolution,
                reasonCode: "update_feed_not_configured"
            )
            return
        }
        guard updaterStarted,
              operationGate.allowsCheck(providerCanCheck: providerCanCheckForUpdates)
        else {
            statusMessage = "The current update action is still in progress."
            traceLogger.emit(UpdateTraceEvent(
                event: .check,
                context: activeTrace.child(),
                status: .skipped,
                reasonCode: "update_check_provider_busy"
            ))
            return
        }

        transition(to: .checking(.manual), reasonCode: "update_check_requested", status: .started)
        emitCheckStarted(trigger: .manual)
        statusMessage = "Checking the \(channel.rawValue) channel for a signed update…"
        updaterController.checkForUpdates(nil)
    }

    func handle(_ route: UpdateRoute) {
        traceLogger.emit(UpdateTraceEvent(
            event: .policy,
            context: UpdateTraceContext(),
            status: .success,
            reasonCode: "update_route_received",
            metadata: UpdateTraceMetadata([.route: route.source.rawValue])
        ))
        switch route.action {
        case .check:
            checkForUpdates()
        case .showAvailability:
            statusMessage = availability == nil
                ? "The update notice is no longer active. Check again for current availability."
                : "The signed update is ready for review."
        }
    }

    func setChannel(_ requestedChannel: UpdateChannel) {
        guard !inertForSignedSmoke else { return }
        guard requestedChannel != channel else { return }
        guard !operationGate.recoveryInProgress,
              !operationGate.restartRequired,
              !updaterController.updater.sessionInProgress,
              pendingInstallHandler == nil,
              availability == nil,
              defaults.string(forKey: SecureUpdatePreferenceKey.retainedCandidateChannel) == nil
        else {
            statusMessage = "Finish, skip, or fully dismiss the current update before changing channels."
            return
        }
        guard (try? feedResolver.resolve(channel: requestedChannel)) != nil else {
            setFailure(
                code: .feedUnavailable,
                message: "No secure HTTPS update feed is configured for the \(requestedChannel.rawValue) channel.",
                state: .feedUnavailable,
                event: .feedResolution,
                reasonCode: "update_channel_feed_not_configured"
            )
            return
        }
        channel = requestedChannel
        defaults.set(requestedChannel.rawValue, forKey: SecureUpdatePreferenceKey.channel)
        availability = nil
        if !updaterStarted {
            startProviderIfConfigured()
        } else {
            updaterController.updater.resetUpdateCycleAfterShortDelay()
        }
        transition(to: .idle, reasonCode: "update_channel_changed", status: .success)
        statusMessage = "Update channel changed to \(requestedChannel.rawValue)."
    }

    func setAutomaticChecksEnabled(_ enabled: Bool) {
        guard !inertForSignedSmoke else { return }
        guard updaterStarted else {
            automaticChecksEnabled = false
            statusMessage = "Automatic checks remain off until a secure HTTPS feed is configured."
            return
        }
        updaterController.updater.automaticallyChecksForUpdates = enabled
        updaterController.updater.automaticallyDownloadsUpdates = false
        automaticChecksEnabled = updaterController.updater.automaticallyChecksForUpdates
        traceLogger.emit(UpdateTraceEvent(
            event: .policy,
            context: UpdateTraceContext(),
            status: .success,
            reasonCode: automaticChecksEnabled
                ? "update_automatic_checks_enabled"
                : "update_automatic_checks_disabled",
            metadata: UpdateTraceMetadata([
                .automatic: String(automaticChecksEnabled),
                .channel: channel.rawValue,
            ])
        ))
        statusMessage = automaticChecksEnabled
            ? "Automatic checks are on; downloading and installation still require your approval."
            : "Automatic checks are off. Use Check for Updates when you want to look."
    }

    func retryBlockedInstallation() {
        guard let pendingInstallHandler,
              readinessTask == nil,
              !operationGate.recoveryInProgress
        else { return }
        beginInstallationPreparation(handler: pendingInstallHandler)
    }

    func shutdownForApplicationTermination() async {
        // A prepared install must leave persistent stores closed for Sparkle's
        // replacement. Normal termination only needs the existing delivery
        // shutdown path.
        if updateLease == nil {
            _ = await readinessCoordinator.snapshot()
        }
    }

    private func startProviderIfConfigured() {
        guard resolveCurrentFeed() != nil else {
            let failure = UpdateFailure(
                code: .feedUnavailable,
                isRecoverable: true,
                consumerMessage: "No secure HTTPS update feed is configured for this channel."
            )
            state = .feedUnavailable(failure)
            statusMessage = failure.consumerMessage
            return
        }
        do {
            try providerStarter(updaterController.updater)
            updaterStarted = true
        } catch {
            updaterStarted = false
            automaticChecksEnabled = false
            let classification = SecureUpdateProviderErrorClassifier.classify(error)
            setFailure(
                code: classification.code,
                message: classification.consumerMessage,
                state: .failed,
                event: .check,
                reasonCode: "update_provider_start_failed"
            )
            return
        }
        automaticChecksEnabled = updaterController.updater.automaticallyChecksForUpdates
        updaterController.updater.automaticallyDownloadsUpdates = false
        statusMessage = automaticChecksEnabled
            ? "Automatic signed update checks are enabled."
            : "Updates are checked only when you ask."
    }

    func emitCheckStarted(trigger: UpdateCheckTrigger) {
        traceLogger.emit(UpdateTraceEvent(
            event: .check,
            context: activeTrace,
            status: .started,
            reasonCode: trigger == .manual ? "update_manual_check_started" : "update_automatic_check_started",
            metadata: UpdateTraceMetadata([
                .channel: channel.rawValue,
                .checkTrigger: trigger.rawValue,
                .currentVersion: currentVersion.marketingVersion,
                .currentBuild: currentVersion.buildVersion,
            ])
        ))
    }

    @discardableResult
    func postAvailabilityNotificationIfNeeded(
        trigger: UpdateCheckTrigger
    ) async -> UpdateAvailabilityNotificationResult {
        guard trigger == .automatic else { return .manualCheckSuppressed }
        let result = await availabilityNotifier.postAvailabilityNotificationIfAuthorized()
        traceLogger.emit(UpdateTraceEvent(
            event: .availability,
            context: activeTrace.child(),
            status: result == .posted ? .success : (result == .failed ? .failed : .skipped),
            reasonCode: "update_notification_\(result.rawValue)",
            metadata: UpdateTraceMetadata([
                .channel: channel.rawValue,
                .checkTrigger: trigger.rawValue,
                .route: UpdateRouteSource.notification.rawValue,
            ])
        ))
        return result
    }

    private func resolveCurrentFeed() -> URL? {
        do {
            let url = try feedResolver.resolve(channel: channel)
            traceLogger.emit(UpdateTraceEvent(
                event: .feedResolution,
                context: activeTrace.child(),
                status: .success,
                reasonCode: "update_feed_resolved",
                metadata: UpdateTraceMetadata([.channel: channel.rawValue])
            ))
            return url
        } catch {
            traceLogger.emit(UpdateTraceEvent(
                event: .feedResolution,
                context: activeTrace.child(),
                status: .failed,
                reasonCode: "update_feed_resolution_failed",
                metadata: UpdateTraceMetadata([.channel: channel.rawValue])
            ))
            return nil
        }
    }

    private func availability(for item: SUAppcastItem) throws -> UpdateAvailability {
        let itemChannel: UpdateChannel
        if let rawChannel = item.channel, !rawChannel.isEmpty {
            guard let parsed = UpdateChannel(rawValue: rawChannel) else {
                throw UpdateFailure(
                    code: .wrongChannel,
                    isRecoverable: false,
                    consumerMessage: "The update belongs to an unsupported release channel."
                )
            }
            itemChannel = parsed
        } else {
            itemChannel = .stable
        }
        guard channel.accepts(candidateChannel: itemChannel) else {
            throw UpdateFailure(
                code: .wrongChannel,
                isRecoverable: false,
                consumerMessage: "The update belongs to a different release channel."
            )
        }
        let rawNotes = item.itemDescriptionFormat == "html"
            ? "See the signed update notice for this release."
            : (item.itemDescription ?? "No release notes were supplied.")
        return UpdateAvailability(
            channel: itemChannel,
            version: UpdateVersion(
                marketingVersion: item.displayVersionString,
                buildVersion: item.versionString
            ),
            releaseNotes: rawNotes,
            publishedAt: item.date,
            contentLength: item.contentLength > UInt64(Int64.max) ? Int64.max : Int64(item.contentLength)
        )
    }

    private func validatedAvailability(for item: SUAppcastItem) throws -> UpdateAvailability {
        let candidate = try availability(for: item)
        let signingSucceeded = item.signingValidationStatus == .succeeded
        let evidence = UpdateSignatureEvidence(
            feedIsSigned: signingSucceeded,
            // Sparkle performs archive EdDSA verification after download. At
            // this pre-download boundary, the archive requirement remains
            // enabled and the appcast candidate is evaluated as expected to
            // carry that signature; a missing/wrong signature fails later in
            // Sparkle before extraction.
            archiveIsSigned: true,
            algorithm: signingSucceeded ? .edDSA : .unknown,
            isDeltaUpdate: item.isDeltaUpdate || item.deltaUpdates?.isEmpty == false
        )
        let result = UpdateCheckResult.evaluate(
            currentVersion: currentVersion,
            candidate: candidate,
            policy: UpdatePolicy(
                channel: channel,
                automaticallyChecksForUpdates: automaticChecksEnabled
            ),
            signatureEvidence: evidence
        )
        switch result.outcome {
        case .available(let availability):
            return availability
        case .rejected(let failure):
            throw failure
        case .noUpdate:
            throw UpdateFailure(
                code: .olderVersion,
                isRecoverable: false,
                consumerMessage: "The offered update is not newer than this installation."
            )
        case .offline(let failure), .feedUnavailable(let failure):
            throw failure
        }
    }

    func beginInstallationPreparation(handler: @escaping () -> Void) {
        guard readinessTask == nil,
              !operationGate.recoveryInProgress,
              !operationGate.restartRequired
        else { return }
        pendingInstallHandler = handler
        let attemptID = operationGate.beginInstallPreparation()
        readinessTask = Task { [weak self] in
            await self?.prepareAndContinueInstallation(handler: handler, attemptID: attemptID)
        }
    }

    private func prepareAndContinueInstallation(
        handler: @escaping () -> Void,
        attemptID: UUID
    ) async {
        defer {
            operationGate.finishInstallPreparation(attemptID)
            readinessTask = nil
        }
        let report = await readinessCoordinator.acquireUpdateLease(
            traceID: activeTrace.traceID,
            parentSpanID: activeTrace.spanID
        )
        guard !Task.isCancelled, operationGate.isCurrentInstallPreparation(attemptID) else {
            if let lateLease = report.lease {
                let disposition = await lateLease.abort()
                if disposition.state != .aborted { operationGate.requireRestart() }
            }
            return
        }
        let blockers = report.blockers.compactMap(Self.installBlocker)
        installReadiness = UpdateInstallReadiness(blockers: blockers)
        guard report.status == .ready, let lease = report.lease else {
            traceLogger.emit(UpdateTraceEvent(
                event: .storeClose,
                context: activeTrace.child(),
                status: report.status == .degraded ? .degraded : .skipped,
                reasonCode: report.reasonCodes.first?.rawValue ?? "update_store_close_blocked",
                metadata: UpdateTraceMetadata([
                    .channel: channel.rawValue,
                    .blockerCount: String(blockers.count),
                ])
            ))
            if let availability {
                transition(
                    to: .installBlocked(availability, installReadiness),
                    reasonCode: report.reasonCodes.first?.rawValue ?? "update_install_blocked",
                    status: report.status == .degraded ? .degraded : .skipped
                )
            }
            pendingInstallHandler = handler
            statusMessage = report.status == .degraded
                ? "Update installation is paused because local stores could not be prepared safely."
                : "Finish active work before installing the update, then retry."
            return
        }

        updateLease = lease
        pendingInstallHandler = nil
        operationGate.finishInstallPreparation(attemptID)
        installReadiness = .ready
        traceLogger.emit(UpdateTraceEvent(
            event: .storeClose,
            context: activeTrace.child(),
            status: .success,
            reasonCode: "update_local_stores_prepared",
            metadata: UpdateTraceMetadata([
                .channel: channel.rawValue,
                .blockerCount: "0",
            ])
        ))
        if let availability {
            transition(to: .installing(availability), reasonCode: "update_install_ready", status: .success)
            persistPendingReceipt(availability: availability)
            traceLogger.emit(UpdateTraceEvent(
                event: .install,
                context: activeTrace.child(),
                status: .started,
                reasonCode: "update_install_handoff_started",
                metadata: UpdateTraceMetadata([
                    .channel: channel.rawValue,
                    .candidateVersion: availability.version.marketingVersion,
                    .candidateBuild: availability.version.buildVersion,
                ])
            ))
        }
        statusMessage = "SwiftData is saved and quiesced; Vault SQLite is closed. SwiftData releases when this process terminates for replacement."
        handler()
    }

    private static func installBlocker(_ blocker: ApplicationUpdateBlocker) -> UpdateInstallBlocker? {
        switch blocker.reasonCode {
        case .deleteAllInProgress, .deleteAllAlreadyInProgress:
            return .deleteAllInProgress
        case .activeFeedWork:
            return .activeFeedWork
        case .activeConnectorWork:
            return .activeConnectorWork
        case .activeSlackWork:
            return .activeSlackWork
        case .activeVaultDatabaseWork:
            return .activeVaultDatabaseWork
        case .activeLocalGenerationWork:
            return .activeLocalGenerationWork
        case .activeChatGeneration:
            return .activeChatGeneration
        case .activeChatToolWork:
            return .activeChatToolWork
        case .activeChatModelAssessment:
            return .activeChatModelAssessment
        case .activeDeliveryRun:
            return .activeDeliveryRun
        case .preparationFailed, .preparationContractIncomplete, .preparationRecoveryIncomplete:
            return .storeCloseFailed
        case .activeWork, .participantBlocked, .updateAlreadyInProgress:
            return .activeSwiftDataWork
        default:
            return nil
        }
    }

    private func persistPendingReceipt(availability: UpdateAvailability) {
        let pending = PendingUpdateReceipt(
            channel: channel,
            previousVersion: currentVersion,
            candidateVersion: availability.version,
            startedAt: .now
        )
        if let data = try? JSONEncoder().encode(pending) {
            defaults.set(data, forKey: SecureUpdatePreferenceKey.pendingReceipt)
        }
    }

    private func abortPreparedStateIfNeeded() async -> Bool {
        guard let updateLease else { return true }
        let disposition = await updateLease.abort()
        self.updateLease = nil
        return disposition.state == .aborted
    }

    private func restorePendingReceiptIfPresent() {
        guard let data = defaults.data(forKey: SecureUpdatePreferenceKey.pendingReceipt),
              let pending = try? JSONDecoder().decode(PendingUpdateReceipt.self, from: data)
        else { return }
        defaults.removeObject(forKey: SecureUpdatePreferenceKey.pendingReceipt)
        defaults.removeObject(forKey: SecureUpdatePreferenceKey.retainedCandidateChannel)
        let receipt = UpdateReceiptReconciler.reconcile(
            pending,
            installedVersion: currentVersion
        )
        activeTrace = UpdateTraceContext()
        transition(
            to: receipt.status == .installed ? .installed(receipt) : .recovered(receipt),
            reasonCode: receipt.reasonCode,
            status: receipt.status == .installed ? .success : .degraded
        )
        traceLogger.emit(UpdateTraceEvent(
            event: .recovery,
            context: activeTrace.child(),
            status: receipt.status == .installed ? .success : .degraded,
            reasonCode: receipt.reasonCode,
            metadata: UpdateTraceMetadata([
                .channel: receipt.channel.rawValue,
                .currentVersion: receipt.resultingVersion.marketingVersion,
                .currentBuild: receipt.resultingVersion.buildVersion,
                .receiptStatus: receipt.status.rawValue,
            ])
        ))
        statusMessage = receipt.status == .installed
            ? "Loki Brief updated successfully to \(currentVersion.marketingVersion) (\(currentVersion.buildVersion))."
            : "The previous update did not replace this app; local state recovery is available."
    }

    private func transition(
        to nextState: UpdateState,
        reasonCode: String,
        status: UpdateTraceStatus
    ) {
        let previous = state.kind
        state = nextState
        traceLogger.emit(UpdateTraceEvent(
            event: .stateTransition,
            context: activeTrace.child(),
            status: status,
            reasonCode: reasonCode,
            metadata: UpdateTraceMetadata([
                .channel: channel.rawValue,
                .transitionFrom: previous.rawValue,
                .transitionTo: nextState.kind.rawValue,
            ])
        ))
    }

    private enum FailureState {
        case offline
        case feedUnavailable
        case failed
    }

    private func setFailure(
        code: UpdateFailureCode,
        message: String,
        state failureState: FailureState,
        event: UpdateTraceEventName,
        reasonCode: String,
        isRecoverable: Bool? = nil
    ) {
        let resolvedRecoverability = isRecoverable ?? Self.defaultRecoverability(for: code)
        let failure = UpdateFailure(
            code: code,
            isRecoverable: resolvedRecoverability,
            consumerMessage: message
        )
        switch failureState {
        case .offline: transition(to: .offline(failure), reasonCode: reasonCode, status: .degraded)
        case .feedUnavailable: transition(to: .feedUnavailable(failure), reasonCode: reasonCode, status: .failed)
        case .failed: transition(to: .failed(failure), reasonCode: reasonCode, status: .failed)
        }
        statusMessage = failure.consumerMessage
        traceLogger.emit(UpdateTraceEvent(
            event: event,
            context: activeTrace.child(),
            status: failureState == .offline ? .degraded : .failed,
            reasonCode: reasonCode,
            metadata: UpdateTraceMetadata([
                .channel: channel.rawValue,
                .retryable: String(failure.isRecoverable),
            ])
        ))
    }

    private static func defaultRecoverability(for code: UpdateFailureCode) -> Bool {
        switch code {
        case .offline, .feedUnavailable, .automaticCheckDisabled, .downloadFailed,
             .installationBlocked, .storeCloseFailed, .relaunchFailed, .providerFailure,
             .incompatibleSystem:
            true
        case .invalidFeedURL, .invalidArchiveURL, .unsignedFeed, .unsignedArchive, .invalidSignature,
             .dsaProhibited, .deltaProhibited, .olderVersion, .wrongChannel,
             .invalidTransition:
            false
        }
    }

    private static func feedConfiguration(bundle: Bundle) -> UpdateFeedConfiguration {
        let keys: [(UpdateChannel, String)] = [
            (.stable, "LOKI_UPDATE_STABLE_FEED_URL"),
            (.beta, "LOKI_UPDATE_BETA_FEED_URL"),
            (.internal, "LOKI_UPDATE_INTERNAL_FEED_URL"),
        ]
        var feeds: [UpdateChannel: URL] = [:]
        for (channel, key) in keys {
            guard let raw = bundle.object(forInfoDictionaryKey: key) as? String,
                  !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let url = URL(string: raw)
            else { continue }
            feeds[channel] = url
        }
        return UpdateFeedConfiguration(feeds: feeds)
    }
}

extension SecureUpdateController: SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        providerAllowedChannels
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        resolveCurrentFeed()?.absoluteString
    }

    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        requestsFirstLaunchUpdateCheckPermission
    }

    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? {
        []
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if updateCheck == .updatesInBackground {
            guard updater.automaticallyChecksForUpdates else {
                throw UpdateFailure(
                    code: .automaticCheckDisabled,
                    isRecoverable: true,
                    consumerMessage: "Automatic update checks are disabled."
                )
            }
            activeTrace = UpdateTraceContext()
            activeCheckTrigger = .automatic
            transition(to: .checking(.automatic), reasonCode: "update_automatic_check_requested", status: .started)
            emitCheckStarted(trigger: .automatic)
        }
        guard resolveCurrentFeed() != nil else {
            throw NSError(
                domain: "com.agentloki.LokiBrief.SecureUpdate",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No secure HTTPS update feed is configured."]
            )
        }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        do {
            let available = try validatedAvailability(for: item)
            availability = available
            transition(to: .updateAvailable(available), reasonCode: "update_available", status: .success)
            traceLogger.emit(UpdateTraceEvent(
                event: .availability,
                context: activeTrace.child(),
                status: .success,
                reasonCode: "update_candidate_available",
                metadata: UpdateTraceMetadata([
                    .channel: channel.rawValue,
                    .checkTrigger: activeCheckTrigger.rawValue,
                    .currentVersion: currentVersion.marketingVersion,
                    .currentBuild: currentVersion.buildVersion,
                    .candidateVersion: available.version.marketingVersion,
                    .candidateBuild: available.version.buildVersion,
                ])
            ))
            if activeCheckTrigger == .automatic {
                Task { [weak self] in
                    _ = await self?.postAvailabilityNotificationIfNeeded(trigger: .automatic)
                }
            }
            statusMessage = "Version \(available.version.marketingVersion) (\(available.version.buildVersion)) is available."
        } catch let failure as UpdateFailure {
            setFailure(
                code: failure.code,
                message: failure.consumerMessage,
                state: .failed,
                event: .availability,
                reasonCode: "update_candidate_rejected"
            )
        } catch {
            setFailure(
                code: .providerFailure,
                message: "The update candidate could not be interpreted safely.",
                state: .failed,
                event: .availability,
                reasonCode: "update_candidate_invalid"
            )
        }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        availability = nil
        defaults.removeObject(forKey: SecureUpdatePreferenceKey.retainedCandidateChannel)
        switch SecureUpdateNoUpdateClassifier.classify(error) {
        case .upToDate:
            transition(to: .upToDate(currentVersion), reasonCode: "update_not_available", status: .success)
            statusMessage = "Loki Brief \(currentVersion.marketingVersion) (\(currentVersion.buildVersion)) is up to date on the \(channel.rawValue) channel."
        case .olderFeed:
            setFailure(
                code: .olderVersion,
                message: "The signed feed only offered a version older than this installation. It was rejected.",
                state: .failed,
                event: .availability,
                reasonCode: "update_older_version_rejected"
            )
        case .incompatibleSystem:
            setFailure(
                code: .incompatibleSystem,
                message: "The signed feed has an update, but it is not compatible with this Mac or macOS version.",
                state: .failed,
                event: .availability,
                reasonCode: "update_system_incompatible"
            )
        case .unknown:
            setFailure(
                code: .providerFailure,
                message: "The signed update check completed without a usable candidate for an unknown reason.",
                state: .failed,
                event: .availability,
                reasonCode: "update_not_available_reason_unknown"
            )
        }
    }

    func updater(
        _ updater: SPUUpdater,
        shouldProceedWithUpdate updateItem: SUAppcastItem,
        updateCheck: SPUUpdateCheck
    ) throws {
        guard updateItem.signingValidationStatus == .succeeded else {
            throw UpdateFailure(
                code: .invalidSignature,
                isRecoverable: false,
                consumerMessage: "The signed update feed could not be verified."
            )
        }
        _ = try validatedAvailability(for: updateItem)
        guard !updateItem.isDeltaUpdate,
              updateItem.deltaUpdates?.isEmpty != false
        else {
            throw UpdateFailure(
                code: .deltaProhibited,
                isRecoverable: false,
                consumerMessage: "Delta updates are not permitted in this release foundation."
            )
        }
        guard let archiveURL = updateItem.fileURL,
              archiveURL.scheme?.lowercased() == "https",
              archiveURL.host?.isEmpty == false,
              archiveURL.user == nil,
              archiveURL.password == nil,
              archiveURL.query == nil,
              archiveURL.fragment == nil,
              !archiveURL.absoluteString.lowercased().contains("token"),
              !archiveURL.absoluteString.lowercased().contains("github_pat_"),
              !archiveURL.absoluteString.lowercased().contains("ghp_")
        else {
            throw UpdateFailure(
                code: .invalidArchiveURL,
                isRecoverable: false,
                consumerMessage: "The update archive URL is not secure."
            )
        }
    }

    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool {
        false
    }

    func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate updateItem: SUAppcastItem,
        state userState: SPUUserUpdateState
    ) {
        switch SecureUpdateChoiceClassifier.classify(choice: choice, stage: userState.stage) {
        case .proceed:
            statusMessage = "Preparing the signed update."
        case .clearAvailability(let reasonCode):
            availability = nil
            defaults.removeObject(forKey: SecureUpdatePreferenceKey.retainedCandidateChannel)
            transition(to: .idle, reasonCode: reasonCode, status: .skipped)
            statusMessage = choice == .skip
                ? "This version was skipped. A manual check can offer it again."
                : "The update was dismissed."
        case .retainDownloaded(let reasonCode):
            defaults.set(channel.rawValue, forKey: SecureUpdatePreferenceKey.retainedCandidateChannel)
            if let availability {
                transition(to: .readyToInstall(availability), reasonCode: reasonCode, status: .success)
            }
            statusMessage = "The validated download is retained. Install or skip it before changing channels."
        case .retainInstalling(let reasonCode):
            defaults.set(channel.rawValue, forKey: SecureUpdatePreferenceKey.retainedCandidateChannel)
            if let availability {
                transition(to: .installing(availability), reasonCode: reasonCode, status: .success)
            }
            statusMessage = "The update remains scheduled for installation when Loki Brief quits."
        }
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        guard let available = try? availability(for: item) else { return }
        transition(
            to: .downloading(
                available,
                UpdateDownloadProgress(receivedBytes: 0, expectedBytes: available.contentLength)
            ),
            reasonCode: "update_download_started",
            status: .started
        )
        statusMessage = "Downloading the signed update…"
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        guard let available = try? availability(for: item) else { return }
        let downloadedBytes = available.contentLength ?? 0
        transition(
            to: .downloading(
                available,
                UpdateDownloadProgress(
                    receivedBytes: downloadedBytes,
                    expectedBytes: available.contentLength
                )
            ),
            reasonCode: "update_download_complete_validation_pending",
            status: .success
        )
        traceLogger.emit(UpdateTraceEvent(
            event: .download,
            context: activeTrace.child(),
            status: .success,
            reasonCode: "update_download_complete_validation_pending",
            metadata: UpdateTraceMetadata([
                .channel: channel.rawValue,
                .candidateVersion: available.version.marketingVersion,
                .candidateBuild: available.version.buildVersion,
                .progressBasisPoints: "10000",
                .byteCount: String(downloadedBytes),
            ])
        ))
        statusMessage = "Download complete. Sparkle is validating the EdDSA signature before extraction."
    }

    func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        statusMessage = "Validating the EdDSA signature and extracting the full update…"
        traceLogger.emit(UpdateTraceEvent(
            event: .signatureValidation,
            context: activeTrace.child(),
            status: .started,
            reasonCode: "update_signature_validation_started",
            metadata: UpdateTraceMetadata([
                .channel: channel.rawValue,
                .signatureAlgorithm: UpdateSignatureAlgorithm.edDSA.rawValue,
            ])
        ))
    }

    func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        guard let available = try? validatedAvailability(for: item) else { return }
        traceLogger.emit(UpdateTraceEvent(
            event: .signatureValidation,
            context: activeTrace.child(),
            status: .success,
            reasonCode: "update_signature_validated_before_extraction",
            metadata: UpdateTraceMetadata([
                .channel: channel.rawValue,
                .signatureAlgorithm: UpdateSignatureAlgorithm.edDSA.rawValue,
                .candidateVersion: available.version.marketingVersion,
                .candidateBuild: available.version.buildVersion,
            ])
        ))
        transition(
            to: .readyToInstall(available),
            reasonCode: "update_full_archive_validated_and_extracted",
            status: .success
        )
        statusMessage = "The signed full update is validated and ready to install."
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        let classification = SecureUpdateProviderErrorClassifier.classify(error)
        let isOffline = classification.code == .offline
        setFailure(
            code: isOffline ? .offline : classification.code,
            message: classification.consumerMessage,
            state: isOffline ? .offline : .failed,
            event: .download,
            reasonCode: classification.reasonCode
        )
    }

    func userDidCancelDownload(_ updater: SPUUpdater) {
        availability = nil
        defaults.removeObject(forKey: SecureUpdatePreferenceKey.retainedCandidateChannel)
        transition(to: .idle, reasonCode: "update_download_cancelled", status: .skipped)
        statusMessage = "Update download cancelled."
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        statusMessage = "Preparing local state for update installation…"
    }

    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        if let available = try? availability(for: item) {
            availability = available
        }
        beginInstallationPreparation(handler: installHandler)
        return true
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        if let availability {
            transition(to: .relaunching(availability), reasonCode: "update_relaunch_started", status: .started)
            traceLogger.emit(UpdateTraceEvent(
                event: .relaunch,
                context: activeTrace.child(),
                status: .started,
                reasonCode: "update_relaunch_started",
                metadata: UpdateTraceMetadata([
                    .channel: channel.rawValue,
                    .candidateVersion: availability.version.marketingVersion,
                    .candidateBuild: availability.version.buildVersion,
                ])
            ))
        }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        beginAbortRecovery(error)
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        guard let error else { return }
        let nsError = error as NSError
        guard nsError.domain == SUSparkleErrorDomain, nsError.code == 4_008 else { return }
        beginAbortRecovery(error)
    }

    func beginAbortRecovery(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == SUSparkleErrorDomain, nsError.code == 1_001 { return }
        let retainsResumableCandidate = nsError.domain == SUSparkleErrorDomain && nsError.code == 4_008
        guard operationGate.beginRecovery() else {
            traceLogger.emit(UpdateTraceEvent(
                event: .recovery,
                context: activeTrace.child(),
                status: .skipped,
                reasonCode: "update_abort_recovery_already_in_progress"
            ))
            return
        }
        let suspendedPreparation = readinessTask
        readinessTask = nil
        operationGate.invalidateInstallPreparation()
        pendingInstallHandler = nil
        if retainsResumableCandidate {
            defaults.set(channel.rawValue, forKey: SecureUpdatePreferenceKey.retainedCandidateChannel)
        } else {
            availability = nil
            defaults.removeObject(forKey: SecureUpdatePreferenceKey.retainedCandidateChannel)
        }
        suspendedPreparation?.cancel()
        let classification = SecureUpdateProviderErrorClassifier.classify(error)
        let pendingData = defaults.data(forKey: SecureUpdatePreferenceKey.pendingReceipt)
        Task {
            defer { operationGate.finishRecovery() }
            await suspendedPreparation?.value
            let preparedStateRecovered = await abortPreparedStateIfNeeded()
            let recovered = preparedStateRecovered && !operationGate.restartRequired
            guard recovered else {
                operationGate.requireRestart()
                setFailure(
                    code: .storeCloseFailed,
                    message: "The update stopped, but one or more local stores could not be reopened safely. Restart Loki Brief before continuing.",
                    state: .failed,
                    event: .recovery,
                    reasonCode: "update_abort_recovery_failed"
                )
                return
            }

            if retainsResumableCandidate {
                if let pendingData,
                   let pending = try? JSONDecoder().decode(PendingUpdateReceipt.self, from: pendingData) {
                    defaults.removeObject(forKey: SecureUpdatePreferenceKey.pendingReceipt)
                    let receipt = UpdateReceiptReconciler.reconcile(
                        pending,
                        installedVersion: currentVersion
                    )
                    traceLogger.emit(UpdateTraceEvent(
                        event: .recovery,
                        context: activeTrace.child(),
                        status: .degraded,
                        reasonCode: "update_install_authorization_deferred_recovered",
                        metadata: UpdateTraceMetadata([
                            .channel: receipt.channel.rawValue,
                            .currentVersion: receipt.resultingVersion.marketingVersion,
                            .currentBuild: receipt.resultingVersion.buildVersion,
                            .receiptStatus: receipt.status.rawValue,
                        ])
                    ))
                }
                setFailure(
                    code: classification.code,
                    message: classification.consumerMessage,
                    state: .failed,
                    event: .recovery,
                    reasonCode: classification.reasonCode
                )
                return
            }

            if let pendingData,
               let pending = try? JSONDecoder().decode(PendingUpdateReceipt.self, from: pendingData) {
                defaults.removeObject(forKey: SecureUpdatePreferenceKey.pendingReceipt)
                let receipt = UpdateReceiptReconciler.reconcile(
                    pending,
                    installedVersion: currentVersion
                )
                transition(
                    to: .recovered(receipt),
                    reasonCode: "\(classification.reasonCode)_recovered",
                    status: .degraded
                )
                traceLogger.emit(UpdateTraceEvent(
                    event: .recovery,
                    context: activeTrace.child(),
                    status: .degraded,
                    reasonCode: receipt.reasonCode,
                    metadata: UpdateTraceMetadata([
                        .channel: receipt.channel.rawValue,
                        .currentVersion: receipt.resultingVersion.marketingVersion,
                        .currentBuild: receipt.resultingVersion.buildVersion,
                        .receiptStatus: receipt.status.rawValue,
                    ])
                ))
                statusMessage = "\(classification.consumerMessage) Local stores were recovered."
                return
            }

            setFailure(
                code: classification.code,
                message: classification.consumerMessage,
                state: classification.code == .offline ? .offline : .failed,
                event: .recovery,
                reasonCode: classification.reasonCode
            )
        }
    }
}

extension SecureUpdateController: @preconcurrency SPUStandardUserDriverDelegate {
    func standardUserDriverShouldShowVersionHistory(for item: SUAppcastItem) -> Bool {
        false
    }

    func standardUserDriverAllowsMinimizableStatusWindow() -> Bool {
        true
    }

    func standardUserDriverWillShowReleaseNotesText(
        _ releaseNotesAttributedString: NSAttributedString,
        forUpdate update: SUAppcastItem,
        withBundleDisplayVersion bundleDisplayVersion: String,
        bundleVersion: String
    ) -> NSAttributedString? {
        let maximum = UpdateAvailability.maximumReleaseNotesCharacters
        guard releaseNotesAttributedString.length > maximum else {
            return releaseNotesAttributedString
        }
        return releaseNotesAttributedString.attributedSubstring(from: NSRange(location: 0, length: maximum))
    }
}
