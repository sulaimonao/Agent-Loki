import Foundation

// MARK: - Channel, version, and availability

public enum UpdateChannel: String, Codable, CaseIterable, Sendable {
    case stable
    case beta
    case `internal`

    public static let `default`: UpdateChannel = .stable

    /// Sparkle's unchannelled/default items are stable releases. Operators on
    /// an opt-in prerelease channel may still receive those stable releases,
    /// while stable operators must never cross into a prerelease channel.
    public func accepts(candidateChannel: UpdateChannel) -> Bool {
        candidateChannel == self || (self != .stable && candidateChannel == .stable)
    }
}

public struct UpdateVersion: Codable, Hashable, Comparable, Sendable {
    public let marketingVersion: String
    public let buildVersion: String

    public init(marketingVersion: String, buildVersion: String) {
        self.marketingVersion = UpdateDomainText.bounded(marketingVersion, limit: 128, fallback: "0")
        self.buildVersion = UpdateDomainText.bounded(buildVersion, limit: 128, fallback: "0")
    }

    public static func < (lhs: UpdateVersion, rhs: UpdateVersion) -> Bool {
        let buildComparison = compareMachineVersion(lhs.buildVersion, rhs.buildVersion)
        if buildComparison != .orderedSame {
            return buildComparison == .orderedAscending
        }

        return UpdateVersionOrdering.compareMarketing(
            lhs.marketingVersion,
            rhs.marketingVersion
        ) == .orderedAscending
    }

    public static func compareMachineVersion(_ lhs: String, _ rhs: String) -> ComparisonResult {
        UpdateVersionOrdering.compareNatural(lhs, rhs)
    }
}

public struct UpdateAvailability: Codable, Equatable, Sendable {
    public static let maximumReleaseNotesCharacters = 4_000

    public let channel: UpdateChannel
    public let version: UpdateVersion
    public let releaseNotes: String
    public let publishedAt: Date?
    public let contentLength: Int64?

    public init(
        channel: UpdateChannel,
        version: UpdateVersion,
        releaseNotes: String,
        publishedAt: Date? = nil,
        contentLength: Int64? = nil
    ) {
        self.channel = channel
        self.version = version
        self.releaseNotes = UpdateDomainText.bounded(
            releaseNotes,
            limit: Self.maximumReleaseNotesCharacters,
            fallback: "",
            allowsLineBreaks: true
        )
        self.publishedAt = publishedAt
        self.contentLength = contentLength.map { max(0, $0) }
    }
}

// MARK: - Feed resolution and signing policy

public struct UpdateFeedConfiguration: Sendable {
    public let feeds: [UpdateChannel: URL]

    public init(feeds: [UpdateChannel: URL]) {
        self.feeds = feeds
    }
}

public enum UpdateFeedResolutionError: Error, Equatable, Sendable {
    case missingChannel(UpdateChannel)
    case invalidScheme
    case missingHost
    case credentialsNotAllowed
    case queryNotAllowed
    case fragmentNotAllowed
    case credentialPatternNotAllowed
}

public struct UpdateFeedResolver: Sendable {
    public let configuration: UpdateFeedConfiguration

    public init(configuration: UpdateFeedConfiguration) {
        self.configuration = configuration
    }

    public func resolve(channel: UpdateChannel = .default) throws -> URL {
        guard let url = configuration.feeds[channel] else {
            throw UpdateFeedResolutionError.missingChannel(channel)
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw UpdateFeedResolutionError.invalidScheme
        }
        guard components.scheme?.lowercased() == "https" else {
            throw UpdateFeedResolutionError.invalidScheme
        }
        guard let host = components.host, !host.isEmpty else {
            throw UpdateFeedResolutionError.missingHost
        }
        guard components.user == nil, components.password == nil else {
            throw UpdateFeedResolutionError.credentialsNotAllowed
        }
        guard components.percentEncodedQuery == nil else {
            throw UpdateFeedResolutionError.queryNotAllowed
        }
        guard components.percentEncodedFragment == nil else {
            throw UpdateFeedResolutionError.fragmentNotAllowed
        }

        let lowercasedURL = url.absoluteString.lowercased()
        let credentialMarkers = [
            "access_token", "auth_token", "private_token", "github_pat_", "ghp_", "xoxb-", "bearer%20"
        ]
        guard !credentialMarkers.contains(where: lowercasedURL.contains) else {
            throw UpdateFeedResolutionError.credentialPatternNotAllowed
        }

        return url
    }
}

public enum UpdateSignatureAlgorithm: String, Codable, CaseIterable, Sendable {
    case edDSA = "eddsa"
    case dsa
    case unknown
}

public struct UpdateSignatureEvidence: Codable, Equatable, Sendable {
    public let feedIsSigned: Bool
    public let archiveIsSigned: Bool
    public let algorithm: UpdateSignatureAlgorithm
    public let isDeltaUpdate: Bool

    public init(
        feedIsSigned: Bool,
        archiveIsSigned: Bool,
        algorithm: UpdateSignatureAlgorithm,
        isDeltaUpdate: Bool = false
    ) {
        self.feedIsSigned = feedIsSigned
        self.archiveIsSigned = archiveIsSigned
        self.algorithm = algorithm
        self.isDeltaUpdate = isDeltaUpdate
    }
}

public struct UpdatePolicy: Codable, Equatable, Sendable {
    public let channel: UpdateChannel
    public let automaticallyChecksForUpdates: Bool
    public let requiresSignedFeed: Bool
    public let requiresSignedArchive: Bool
    public let allowsDeltaUpdates: Bool

    public init(
        channel: UpdateChannel = .default,
        automaticallyChecksForUpdates: Bool = false
    ) {
        self.channel = channel
        self.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        self.requiresSignedFeed = true
        self.requiresSignedArchive = true
        self.allowsDeltaUpdates = false
    }

    public func failure(for evidence: UpdateSignatureEvidence) -> UpdateFailure? {
        if requiresSignedFeed, !evidence.feedIsSigned {
            return UpdateFailure(
                code: .unsignedFeed,
                isRecoverable: false,
                consumerMessage: "The update feed was not signed."
            )
        }
        if requiresSignedArchive, !evidence.archiveIsSigned {
            return UpdateFailure(
                code: .unsignedArchive,
                isRecoverable: false,
                consumerMessage: "The update archive was not signed."
            )
        }
        if evidence.algorithm == .dsa {
            return UpdateFailure(
                code: .dsaProhibited,
                isRecoverable: false,
                consumerMessage: "The update uses a prohibited signature algorithm."
            )
        }
        if evidence.algorithm != .edDSA {
            return UpdateFailure(
                code: .invalidSignature,
                isRecoverable: false,
                consumerMessage: "The update signature could not be verified."
            )
        }
        if evidence.isDeltaUpdate, !allowsDeltaUpdates {
            return UpdateFailure(
                code: .deltaProhibited,
                isRecoverable: false,
                consumerMessage: "Delta updates are not permitted."
            )
        }
        return nil
    }
}

public struct UpdateArchiveEvidence: Equatable, Sendable {
    public let expectedSHA256: String
    public let observedSHA256: String
    public let signatureEvidence: UpdateSignatureEvidence

    public init(
        expectedSHA256: String,
        observedSHA256: String,
        signatureEvidence: UpdateSignatureEvidence
    ) {
        self.expectedSHA256 = expectedSHA256.lowercased()
        self.observedSHA256 = observedSHA256.lowercased()
        self.signatureEvidence = signatureEvidence
    }
}

public enum UpdateArchiveEvidenceValidator {
    public static func failure(
        for evidence: UpdateArchiveEvidence,
        policy: UpdatePolicy
    ) -> UpdateFailure? {
        if let signatureFailure = policy.failure(for: evidence.signatureEvidence) {
            return signatureFailure
        }
        guard isSHA256(evidence.expectedSHA256),
              isSHA256(evidence.observedSHA256),
              evidence.expectedSHA256 == evidence.observedSHA256
        else {
            return UpdateFailure(
                code: .invalidSignature,
                isRecoverable: false,
                consumerMessage: "The downloaded update archive was altered or has an invalid checksum."
            )
        }
        return nil
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }
}

public enum UpdateRouteSource: String, Codable, CaseIterable, Sendable {
    case appMenu = "app_menu"
    case menuBar = "menu_bar"
    case settings
    case notification
}

public enum UpdateRouteAction: String, Codable, Sendable {
    case check
    case showAvailability = "show_availability"
}

public struct UpdateRoute: Codable, Equatable, Sendable {
    public static let availabilityNotificationIdentifier = "com.agentloki.LokiBrief.update.available"
    public static let availabilityNotificationCategoryIdentifier = "com.agentloki.LokiBrief.update"

    public let source: UpdateRouteSource
    public let action: UpdateRouteAction

    public init(source: UpdateRouteSource, action: UpdateRouteAction) {
        self.source = source
        self.action = action
    }

    public static func check(from source: UpdateRouteSource) -> UpdateRoute {
        UpdateRoute(source: source, action: .check)
    }

    public static func notification(identifier: String) -> UpdateRoute? {
        guard identifier == availabilityNotificationIdentifier else { return nil }
        return UpdateRoute(source: .notification, action: .showAvailability)
    }
}

// MARK: - Results, readiness, failures, and receipts

public enum UpdateFailureCode: String, Codable, CaseIterable, Sendable {
    case offline
    case feedUnavailable = "feed_unavailable"
    case invalidFeedURL = "invalid_feed_url"
    case invalidArchiveURL = "invalid_archive_url"
    case unsignedFeed = "unsigned_feed"
    case unsignedArchive = "unsigned_archive"
    case invalidSignature = "invalid_signature"
    case dsaProhibited = "dsa_prohibited"
    case deltaProhibited = "delta_prohibited"
    case automaticCheckDisabled = "automatic_check_disabled"
    case olderVersion = "older_version"
    case wrongChannel = "wrong_channel"
    case incompatibleSystem = "incompatible_system"
    case downloadFailed = "download_failed"
    case installationBlocked = "installation_blocked"
    case storeCloseFailed = "store_close_failed"
    case relaunchFailed = "relaunch_failed"
    case providerFailure = "provider_failure"
    case invalidTransition = "invalid_transition"
}

public struct UpdateFailure: Error, LocalizedError, CustomNSError, Codable, Equatable, Sendable {
    public static let errorDomain = "com.agentloki.LokiBrief.UpdateFailure"
    public static let failureCodeUserInfoKey = "LokiBriefUpdateFailureCode"
    public static let recoverableUserInfoKey = "LokiBriefUpdateFailureRecoverable"

    public let code: UpdateFailureCode
    public let isRecoverable: Bool
    public let consumerMessage: String

    public init(
        code: UpdateFailureCode,
        isRecoverable: Bool,
        consumerMessage: String
    ) {
        self.code = code
        self.isRecoverable = isRecoverable
        self.consumerMessage = UpdateDomainText.bounded(
            consumerMessage,
            limit: 256,
            fallback: "The update could not be completed."
        )
    }

    public var errorDescription: String? { consumerMessage }

    public var errorCode: Int { 1 }

    public var errorUserInfo: [String: Any] {
        [
            NSLocalizedDescriptionKey: consumerMessage,
            Self.failureCodeUserInfoKey: code.rawValue,
            Self.recoverableUserInfoKey: isRecoverable,
        ]
    }
}

public enum UpdateInstallBlocker: String, Codable, CaseIterable, Comparable, Sendable {
    case activeFeedWork = "active_feed_work"
    case activeConnectorWork = "active_connector_work"
    case activeSlackWork = "active_slack_work"
    case activeVaultDatabaseWork = "active_vault_database_work"
    case activeLocalGenerationWork = "active_local_generation_work"
    case activeChatGeneration = "active_chat_generation"
    case activeChatToolWork = "active_chat_tool_work"
    case activeChatModelAssessment = "active_chat_model_assessment"
    case activeSwiftDataWork = "active_swift_data_work"
    case activeDeliveryRun = "active_delivery_run"
    case deleteAllInProgress = "delete_all_in_progress"
    case storeCloseFailed = "store_close_failed"

    public static func < (lhs: UpdateInstallBlocker, rhs: UpdateInstallBlocker) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct UpdateInstallReadiness: Codable, Equatable, Sendable {
    public let blockers: [UpdateInstallBlocker]

    public init(blockers: [UpdateInstallBlocker] = []) {
        self.blockers = Array(Set(blockers)).sorted()
    }

    public static let ready = UpdateInstallReadiness()

    public var isReady: Bool {
        blockers.isEmpty
    }

    public var reasonCode: String {
        isReady ? "update_install_ready" : "update_install_blocked"
    }
}

public enum UpdateCheckTrigger: String, Codable, Sendable {
    case manual
    case automatic
}

public enum UpdateCheckOutcome: Codable, Equatable, Sendable {
    case noUpdate(UpdateVersion)
    case available(UpdateAvailability)
    case offline(UpdateFailure)
    case feedUnavailable(UpdateFailure)
    case rejected(UpdateFailure)
}

public struct UpdateCheckResult: Codable, Equatable, Sendable {
    public let checkedAt: Date
    public let channel: UpdateChannel
    public let outcome: UpdateCheckOutcome

    public init(
        checkedAt: Date = Date(),
        channel: UpdateChannel,
        outcome: UpdateCheckOutcome
    ) {
        self.checkedAt = checkedAt
        self.channel = channel
        self.outcome = outcome
    }

    public static func evaluate(
        currentVersion: UpdateVersion,
        candidate: UpdateAvailability?,
        policy: UpdatePolicy,
        signatureEvidence: UpdateSignatureEvidence,
        checkedAt: Date = Date()
    ) -> UpdateCheckResult {
        if let signatureFailure = policy.failure(for: signatureEvidence) {
            return UpdateCheckResult(
                checkedAt: checkedAt,
                channel: policy.channel,
                outcome: .rejected(signatureFailure)
            )
        }

        guard let candidate else {
            return UpdateCheckResult(
                checkedAt: checkedAt,
                channel: policy.channel,
                outcome: .noUpdate(currentVersion)
            )
        }
        guard policy.channel.accepts(candidateChannel: candidate.channel) else {
            return UpdateCheckResult(
                checkedAt: checkedAt,
                channel: policy.channel,
                outcome: .rejected(
                    UpdateFailure(
                        code: .wrongChannel,
                        isRecoverable: false,
                        consumerMessage: "The update belongs to a different release channel."
                    )
                )
            )
        }

        let machineVersionComparison = UpdateVersion.compareMachineVersion(
            candidate.version.buildVersion,
            currentVersion.buildVersion
        )
        if machineVersionComparison == .orderedAscending {
            return UpdateCheckResult(
                checkedAt: checkedAt,
                channel: policy.channel,
                outcome: .rejected(
                    UpdateFailure(
                        code: .olderVersion,
                        isRecoverable: false,
                        consumerMessage: "The offered update is older than the installed version."
                    )
                )
            )
        }

        return UpdateCheckResult(
            checkedAt: checkedAt,
            channel: policy.channel,
            outcome: machineVersionComparison == .orderedSame
                ? .noUpdate(currentVersion)
                : .available(candidate)
        )
    }
}

public struct UpdateDownloadProgress: Codable, Equatable, Sendable {
    public let receivedBytes: Int64
    public let expectedBytes: Int64?

    public init(receivedBytes: Int64, expectedBytes: Int64? = nil) {
        self.receivedBytes = max(0, receivedBytes)
        self.expectedBytes = expectedBytes.map { max(0, $0) }
    }

    public var fractionCompleted: Double? {
        guard let expectedBytes, expectedBytes > 0 else {
            return nil
        }
        return min(1, Double(receivedBytes) / Double(expectedBytes))
    }

    public var basisPoints: Int? {
        fractionCompleted.map { Int(($0 * 10_000).rounded(.down)) }
    }
}

public enum UpdateReceiptStatus: String, Codable, Sendable {
    case installed
    case recovered
    case failed
}

public struct UpdateReceipt: Codable, Equatable, Sendable {
    public let receiptID: UUID
    public let channel: UpdateChannel
    public let previousVersion: UpdateVersion
    public let resultingVersion: UpdateVersion
    public let status: UpdateReceiptStatus
    public let startedAt: Date
    public let completedAt: Date
    public let reasonCode: String

    public init(
        receiptID: UUID = UUID(),
        channel: UpdateChannel,
        previousVersion: UpdateVersion,
        resultingVersion: UpdateVersion,
        status: UpdateReceiptStatus,
        startedAt: Date,
        completedAt: Date,
        reasonCode: String
    ) {
        self.receiptID = receiptID
        self.channel = channel
        self.previousVersion = previousVersion
        self.resultingVersion = resultingVersion
        self.status = status
        self.startedAt = startedAt
        self.completedAt = max(startedAt, completedAt)
        self.reasonCode = UpdateDomainText.reasonCode(reasonCode)
    }
}

struct PendingUpdateReceipt: Codable, Equatable, Sendable {
    let channel: UpdateChannel
    let previousVersion: UpdateVersion
    let candidateVersion: UpdateVersion
    let startedAt: Date
}

enum UpdateReceiptReconciler {
    static func reconcile(
        _ pending: PendingUpdateReceipt,
        installedVersion: UpdateVersion,
        completedAt: Date = .now
    ) -> UpdateReceipt {
        let installed = installedVersion == pending.candidateVersion
        return UpdateReceipt(
            channel: pending.channel,
            previousVersion: pending.previousVersion,
            resultingVersion: installedVersion,
            status: installed ? .installed : .recovered,
            startedAt: pending.startedAt,
            completedAt: completedAt,
            reasonCode: installed
                ? "update_install_receipt_confirmed"
                : "update_install_receipt_recovered_without_replacement"
        )
    }
}

// MARK: - Deterministic update state machine

public enum UpdateState: Codable, Equatable, Sendable {
    case idle
    case checking(UpdateCheckTrigger)
    case updateAvailable(UpdateAvailability)
    case downloading(UpdateAvailability, UpdateDownloadProgress)
    case readyToInstall(UpdateAvailability)
    case installBlocked(UpdateAvailability, UpdateInstallReadiness)
    case installing(UpdateAvailability)
    case relaunching(UpdateAvailability)
    case upToDate(UpdateVersion)
    case offline(UpdateFailure)
    case feedUnavailable(UpdateFailure)
    case failed(UpdateFailure)
    case installed(UpdateReceipt)
    case recovered(UpdateReceipt)

    public var kind: UpdateStateKind {
        switch self {
        case .idle: .idle
        case .checking: .checking
        case .updateAvailable: .updateAvailable
        case .downloading: .downloading
        case .readyToInstall: .readyToInstall
        case .installBlocked: .installBlocked
        case .installing: .installing
        case .relaunching: .relaunching
        case .upToDate: .upToDate
        case .offline: .offline
        case .feedUnavailable: .feedUnavailable
        case .failed: .failed
        case .installed: .installed
        case .recovered: .recovered
        }
    }
}

public enum UpdateStateKind: String, Codable, CaseIterable, Sendable {
    case idle
    case checking
    case updateAvailable = "update_available"
    case downloading
    case readyToInstall = "ready_to_install"
    case installBlocked = "install_blocked"
    case installing
    case relaunching
    case upToDate = "up_to_date"
    case offline
    case feedUnavailable = "feed_unavailable"
    case failed
    case installed
    case recovered
}

public enum UpdateEvent: Equatable, Sendable {
    case requestCheck(UpdateCheckTrigger)
    case checkCompleted(UpdateCheckResult)
    case beginDownload
    case reportDownloadProgress(UpdateDownloadProgress)
    case downloadCompleted
    case downloadFailed(UpdateFailure)
    case requestInstall(UpdateInstallReadiness)
    case beginRelaunch
    case relaunchSucceeded(UpdateReceipt)
    case recoveryCompleted(UpdateReceipt)
    case retry
    case reset

    public var name: String {
        switch self {
        case .requestCheck: "request_check"
        case .checkCompleted: "check_completed"
        case .beginDownload: "begin_download"
        case .reportDownloadProgress: "report_download_progress"
        case .downloadCompleted: "download_completed"
        case .downloadFailed: "download_failed"
        case .requestInstall: "request_install"
        case .beginRelaunch: "begin_relaunch"
        case .relaunchSucceeded: "relaunch_succeeded"
        case .recoveryCompleted: "recovery_completed"
        case .retry: "retry"
        case .reset: "reset"
        }
    }
}

public struct UpdateStateTransitionError: Error, Equatable, Sendable {
    public let state: UpdateStateKind
    public let event: String

    public init(state: UpdateStateKind, event: String) {
        self.state = state
        self.event = event
    }
}

public struct UpdateStateMachine: Sendable {
    public let policy: UpdatePolicy
    public private(set) var state: UpdateState

    public init(policy: UpdatePolicy = UpdatePolicy(), initialState: UpdateState = .idle) {
        self.policy = policy
        self.state = initialState
    }

    @discardableResult
    public mutating func transition(_ event: UpdateEvent) throws -> UpdateState {
        let nextState: UpdateState

        switch (state, event) {
        case (_, .reset):
            nextState = .idle

        case (.idle, .requestCheck(let trigger)),
             (.upToDate, .requestCheck(let trigger)),
             (.installed, .requestCheck(let trigger)),
             (.recovered, .requestCheck(let trigger)):
            if trigger == .automatic, !policy.automaticallyChecksForUpdates {
                nextState = .failed(
                    UpdateFailure(
                        code: .automaticCheckDisabled,
                        isRecoverable: true,
                        consumerMessage: "Automatic update checks are disabled."
                    )
                )
            } else {
                nextState = .checking(trigger)
            }

        case (.checking, .checkCompleted(let result)):
            guard result.channel == policy.channel else {
                nextState = .failed(
                    UpdateFailure(
                        code: .wrongChannel,
                        isRecoverable: false,
                        consumerMessage: "The update result belongs to a different release channel."
                    )
                )
                break
            }
            switch result.outcome {
            case .noUpdate(let currentVersion):
                nextState = .upToDate(currentVersion)
            case .available(let availability):
                if policy.channel.accepts(candidateChannel: availability.channel) {
                    nextState = .updateAvailable(availability)
                } else {
                    nextState = .failed(
                        UpdateFailure(
                            code: .wrongChannel,
                            isRecoverable: false,
                            consumerMessage: "The update belongs to a different release channel."
                        )
                    )
                }
            case .offline(let failure):
                nextState = .offline(failure)
            case .feedUnavailable(let failure):
                nextState = .feedUnavailable(failure)
            case .rejected(let failure):
                nextState = .failed(failure)
            }

        case (.updateAvailable(let availability), .beginDownload):
            nextState = .downloading(
                availability,
                UpdateDownloadProgress(receivedBytes: 0, expectedBytes: availability.contentLength)
            )

        case (.downloading(let availability, _), .reportDownloadProgress(let progress)):
            nextState = .downloading(availability, progress)

        case (.downloading(let availability, _), .downloadCompleted):
            nextState = .readyToInstall(availability)

        case (.downloading, .downloadFailed(let failure)):
            nextState = .failed(failure)

        case (.readyToInstall(let availability), .requestInstall(let readiness)),
             (.installBlocked(let availability, _), .requestInstall(let readiness)):
            if readiness.isReady {
                nextState = .installing(availability)
            } else {
                nextState = .installBlocked(availability, readiness)
            }

        case (.installing(let availability), .beginRelaunch):
            nextState = .relaunching(availability)

        case (.relaunching, .relaunchSucceeded(let receipt)):
            nextState = .installed(receipt)

        case (.relaunching, .recoveryCompleted(let receipt)),
             (.failed, .recoveryCompleted(let receipt)),
             (.offline, .recoveryCompleted(let receipt)),
             (.feedUnavailable, .recoveryCompleted(let receipt)):
            nextState = .recovered(receipt)

        case (.offline, .retry),
             (.feedUnavailable, .retry),
             (.failed, .retry):
            nextState = .checking(.manual)

        case (.installBlocked(let availability, _), .retry):
            nextState = .readyToInstall(availability)

        default:
            throw UpdateStateTransitionError(state: state.kind, event: event.name)
        }

        state = nextState
        return nextState
    }
}

// MARK: - Internal bounded text and version ordering helpers

enum UpdateDomainText {
    private static let forbiddenDirectionalScalars: Set<UInt32> = [
        0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
        0x2066, 0x2067, 0x2068, 0x2069
    ]

    static func bounded(
        _ value: String,
        limit: Int,
        fallback: String,
        allowsLineBreaks: Bool = false
    ) -> String {
        let scalars = value.unicodeScalars.filter { scalar in
            if forbiddenDirectionalScalars.contains(scalar.value) {
                return false
            }
            if allowsLineBreaks, scalar == "\n" || scalar == "\t" {
                return true
            }
            return !CharacterSet.controlCharacters.contains(scalar)
        }
        let sanitized = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bounded = String(sanitized.prefix(max(0, limit)))
        return bounded.isEmpty ? fallback : bounded
    }

    static func reasonCode(_ value: String) -> String {
        let boundedValue = bounded(value.lowercased(), limit: 96, fallback: "update_reason_unspecified")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_.-")
        guard boundedValue.unicodeScalars.allSatisfy(allowed.contains) else {
            return "update_reason_invalid"
        }
        return boundedValue
    }
}

private enum UpdateVersionOrdering {
    private struct SemanticVersion {
        let core: [String]
        let prerelease: [String]?

        init(_ rawValue: String) {
            let withoutBuildMetadata = rawValue.split(
                separator: "+",
                maxSplits: 1,
                omittingEmptySubsequences: false
            ).first.map(String.init) ?? rawValue
            let components = withoutBuildMetadata.split(
                separator: "-",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            self.core = components.first.map {
                $0.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            } ?? ["0"]
            if components.count == 2, !components[1].isEmpty {
                self.prerelease = components[1]
                    .split(separator: ".", omittingEmptySubsequences: false)
                    .map(String.init)
            } else {
                self.prerelease = nil
            }
        }
    }

    static func compareMarketing(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = SemanticVersion(lhs)
        let right = SemanticVersion(rhs)
        let coreCount = max(left.core.count, right.core.count)

        for index in 0..<coreCount {
            let leftComponent = index < left.core.count ? left.core[index] : "0"
            let rightComponent = index < right.core.count ? right.core[index] : "0"
            let comparison = compareIdentifier(leftComponent, rightComponent, numericIdentifiersSortFirst: false)
            if comparison != .orderedSame {
                return comparison
            }
        }

        switch (left.prerelease, right.prerelease) {
        case (nil, nil):
            return .orderedSame
        case (nil, .some):
            return .orderedDescending
        case (.some, nil):
            return .orderedAscending
        case (.some(let leftIdentifiers), .some(let rightIdentifiers)):
            let identifierCount = max(leftIdentifiers.count, rightIdentifiers.count)
            for index in 0..<identifierCount {
                guard index < leftIdentifiers.count else { return .orderedAscending }
                guard index < rightIdentifiers.count else { return .orderedDescending }
                let comparison = compareIdentifier(
                    leftIdentifiers[index],
                    rightIdentifiers[index],
                    numericIdentifiersSortFirst: true
                )
                if comparison != .orderedSame {
                    return comparison
                }
            }
            return .orderedSame
        }
    }

    static func compareNatural(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let leftTokens = naturalTokens(lhs)
        let rightTokens = naturalTokens(rhs)
        let count = max(leftTokens.count, rightTokens.count)

        for index in 0..<count {
            guard index < leftTokens.count else { return .orderedAscending }
            guard index < rightTokens.count else { return .orderedDescending }
            let comparison = compareIdentifier(
                leftTokens[index],
                rightTokens[index],
                numericIdentifiersSortFirst: true
            )
            if comparison != .orderedSame {
                return comparison
            }
        }
        return .orderedSame
    }

    private static func naturalTokens(_ value: String) -> [String] {
        guard !value.isEmpty else { return ["0"] }
        var result: [String] = []
        var current = ""
        var currentIsNumeric: Bool?

        for character in value {
            let isNumeric = character.isASCII && character.isNumber
            if let currentIsNumeric, currentIsNumeric != isNumeric {
                result.append(current)
                current = ""
            }
            current.append(character)
            currentIsNumeric = isNumeric
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    private static func compareIdentifier(
        _ lhs: String,
        _ rhs: String,
        numericIdentifiersSortFirst: Bool
    ) -> ComparisonResult {
        let lhsIsNumeric = isASCIINumber(lhs)
        let rhsIsNumeric = isASCIINumber(rhs)

        if lhsIsNumeric, rhsIsNumeric {
            return compareUnboundedNumbers(lhs, rhs)
        }
        if numericIdentifiersSortFirst, lhsIsNumeric != rhsIsNumeric {
            return lhsIsNumeric ? .orderedAscending : .orderedDescending
        }

        let leftFolded = lhs.lowercased()
        let rightFolded = rhs.lowercased()
        if leftFolded < rightFolded { return .orderedAscending }
        if leftFolded > rightFolded { return .orderedDescending }
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }

    private static func isASCIINumber(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }

    private static func compareUnboundedNumbers(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = String(lhs.drop(while: { $0 == "0" }))
        let right = String(rhs.drop(while: { $0 == "0" }))
        let normalizedLeft = left.isEmpty ? "0" : left
        let normalizedRight = right.isEmpty ? "0" : right

        if normalizedLeft.count < normalizedRight.count { return .orderedAscending }
        if normalizedLeft.count > normalizedRight.count { return .orderedDescending }
        if normalizedLeft < normalizedRight { return .orderedAscending }
        if normalizedLeft > normalizedRight { return .orderedDescending }
        return .orderedSame
    }
}
