import AppKit
import Darwin
import Foundation
import OSLog

enum LokiCanonicalFileURL {
    static func existing(
        _ URL: URL,
        isDirectory: Bool
    ) -> URL? {
        let path: String? = URL.path.withCString { source in
            guard let resolved = Darwin.realpath(source, nil) else {
                return nil
            }
            defer { Darwin.free(resolved) }
            return String(cString: resolved)
        }
        return path.map {
            Foundation.URL(
                fileURLWithPath: $0,
                isDirectory: isDirectory
            )
        }
    }

    static func lexical(
        _ URL: URL,
        isDirectory: Bool? = nil
    ) -> URL {
        let components = URL.path.split(
            separator: "/",
            omittingEmptySubsequences: true
        )
        var normalized: [Substring] = []
        for component in components {
            switch component {
            case ".":
                continue
            case "..":
                if !normalized.isEmpty {
                    normalized.removeLast()
                }
            default:
                normalized.append(component)
            }
        }
        let path = "/" + normalized.joined(separator: "/")
        return Foundation.URL(
            fileURLWithPath: path,
            isDirectory: isDirectory ?? URL.hasDirectoryPath
        )
    }
}

enum NavigationDestination: String, CaseIterable, Identifiable { case today = "Today", chat = "Agent Loki", sources = "Sources", vault = "Vault", models = "Local Models", history = "History", delivery = "Delivery", settings = "Settings", privacy = "About & Privacy"; var id: String { rawValue } }

enum BriefPresentationContext: Equatable, Sendable {
    case today
    case historical
}

private enum FeedRefreshOutcome: Sendable {
    case success(FeedFetchResult)
    case failure(subscription: FeedSubscription, failure: FeedFetchFailure, traceID: String, failedAt: Date)
}

enum LokiLaunchStorageClassification: String, Codable, CaseIterable, Sendable {
    case production
    case xctestInMemory = "xctest_in_memory"
    case xctestIsolatedDisk = "xctest_isolated_disk"
    case signedSmokeIsolatedDisk = "signed_smoke_isolated_disk"
    case invalidIsolationIntent = "invalid_isolation_intent"
}

enum LokiLaunchStorageRequestedMode: String, Codable, Sendable {
    case production
    case xctest
    case signedSmoke = "signed_smoke"
    case conflicting
    case unspecifiedIsolation = "unspecified_isolation"
}

enum LokiLaunchStorageValidationOutcome: String, Codable, Sendable {
    case notRequired = "not_required"
    case valid
    case invalid
}

enum LokiLaunchStorageReasonCode: String, Codable, CaseIterable, Error, Sendable {
    case productionSelected = "persistence_production_selected"
    case xctestInMemorySelected = "persistence_xctest_in_memory_selected"
    case xctestIsolatedDiskSelected = "persistence_xctest_isolated_disk_selected"
    case signedSmokeIsolatedDiskSelected = "persistence_signed_smoke_isolated_disk_selected"
    case malformedArguments = "persistence_isolation_arguments_malformed"
    case conflictingLaunchModes = "persistence_isolation_launch_modes_conflict"
    case conflictingRoots = "persistence_isolation_roots_conflict"
    case signedSmokeRootMissing = "persistence_signed_smoke_root_missing"
    case rootWithoutMode = "persistence_isolation_root_without_mode"
    case rootEmpty = "persistence_isolation_root_empty"
    case rootRelative = "persistence_isolation_root_relative"
    case rootProductionContainer = "persistence_isolation_root_production_container"
    case rootProductionStoreFilename = "persistence_isolation_root_production_store_filename"
    case rootRecoverySource = "persistence_isolation_root_recovery_source"
    case rootExternalVolume = "persistence_isolation_root_external_volume"
    case rootBackupOrSnapshot = "persistence_isolation_root_backup_or_snapshot"
    case rootOutsideTemporaryDirectory = "persistence_isolation_root_outside_temporary_directory"
    case rootParentMissing = "persistence_isolation_root_parent_missing"
    case rootParentNotDirectory = "persistence_isolation_root_parent_not_directory"
    case rootNotDirectory = "persistence_isolation_root_not_directory"
    case rootSymlinkEscape = "persistence_isolation_root_symlink_escape"
    case rootUnavailable = "persistence_isolation_root_unavailable"
    case signedSmokeStoreMissing = "persistence_signed_smoke_store_missing"
    case signedSmokeVaultMissing = "persistence_signed_smoke_vault_missing"
    case signedSmokePairInvalid = "persistence_signed_smoke_pair_invalid"
}

struct LokiLaunchStorageEvidence: Codable, Equatable, Sendable {
    let event = "persistence_store_selection"
    let component = "application_startup"
    let status: String
    let reasonCode: String
    let requestedLaunchMode: String
    let resolvedStorageClassification: String
    let validationOutcome: String
    let swiftDataVaultPaired: Bool

    enum CodingKeys: String, CodingKey {
        case event
        case component
        case status
        case reasonCode = "reason_code"
        case requestedLaunchMode = "requested_launch_mode"
        case resolvedStorageClassification = "resolved_storage_classification"
        case validationOutcome = "validation_outcome"
        case swiftDataVaultPaired = "swiftdata_vault_paired"
    }
}

struct LokiLaunchStoragePlan: Equatable, Sendable {
    let classification: LokiLaunchStorageClassification
    let rootURL: URL?
    let swiftDataURL: URL?
    let vaultURL: URL?
    let reasonCode: LokiLaunchStorageReasonCode
    let evidence: LokiLaunchStorageEvidence

    var isValid: Bool {
        classification != .invalidIsolationIntent
    }
}

struct LokiLaunchStoragePathPolicy: Sendable {
    let approvedTemporaryRoots: [URL]
    let productionApplicationSupportRoot: URL
    let recoveryRoots: [URL]

    static func live(fileManager: FileManager = .default) -> LokiLaunchStoragePathPolicy {
        let userHomePath = NSHomeDirectoryForUser(NSUserName()) ?? NSHomeDirectory()
        let userHome = URL(fileURLWithPath: userHomePath, isDirectory: true)
        let productionContainer = userHome
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Containers", isDirectory: true)
            .appendingPathComponent("com.agentloki.LokiBrief", isDirectory: true)
        let productionData = productionContainer.appendingPathComponent("Data", isDirectory: true)
        let productionTemporary = productionData.appendingPathComponent("tmp", isDirectory: true)
        let roots = [
            fileManager.temporaryDirectory,
            URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            URL(fileURLWithPath: "/private/tmp", isDirectory: true),
        ]
        return LokiLaunchStoragePathPolicy(
            approvedTemporaryRoots: roots,
            productionApplicationSupportRoot: productionData
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true),
            recoveryRoots: [
                productionTemporary.appendingPathComponent(
                    "loki-p7-production-recovery.0uRiiQ",
                    isDirectory: true
                ),
                productionTemporary.appendingPathComponent(
                    "loki-p7-production-restore-authorized.TXxK2a",
                    isDirectory: true
                ),
            ]
        )
    }
}

enum LokiLaunchStorageResolver {
    static let signedSmokeSentinel = "--loki-signed-smoke"
    static let isolatedRootArgument = "--loki-isolated-data-root"
    static let isolatedRootEnvironment = "LOKI_BRIEF_ISOLATED_TEST_DATA_ROOT"

    private struct ParsedArguments {
        var signedSmokeCount = 0
        var rootValues: [String] = []
        var malformed = false
    }

    static func resolve(
        arguments: [String],
        environment: [String: String],
        isXCTest: Bool,
        explicitTestDataRoot: URL? = nil,
        pathPolicy: LokiLaunchStoragePathPolicy = .live(),
        fileManager: FileManager = .default
    ) -> LokiLaunchStoragePlan {
        let parsed = parse(arguments: arguments)
        let environmentRootPresent = environment.keys.contains(isolatedRootEnvironment)
        let environmentRoot = environmentRootPresent
            ? environment[isolatedRootEnvironment] ?? ""
            : nil
        let explicitRoot = explicitTestDataRoot?.path
        let allRootValues = parsed.rootValues
            + (environmentRoot.map { [$0] } ?? [])
            + (explicitRoot.map { [$0] } ?? [])

        if parsed.malformed || parsed.signedSmokeCount > 1 || parsed.rootValues.count > 1 {
            return invalid(
                requested: parsed.signedSmokeCount > 0 ? .signedSmoke : (isXCTest ? .xctest : .unspecifiedIsolation),
                reason: parsed.rootValues.count > 1 ? .conflictingRoots : .malformedArguments
            )
        }
        if parsed.signedSmokeCount == 1, isXCTest {
            return invalid(requested: .conflicting, reason: .conflictingLaunchModes)
        }

        let normalizedValues = allRootValues.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if Set(normalizedValues).count > 1 {
            return invalid(
                requested: parsed.signedSmokeCount == 1 ? .signedSmoke : (isXCTest ? .xctest : .unspecifiedIsolation),
                reason: .conflictingRoots
            )
        }

        if parsed.signedSmokeCount == 1 {
            guard let commandRoot = parsed.rootValues.first else {
                return invalid(requested: .signedSmoke, reason: .signedSmokeRootMissing)
            }
            return diskPlan(
                requested: .signedSmoke,
                classification: .signedSmokeIsolatedDisk,
                successReason: .signedSmokeIsolatedDiskSelected,
                rawRoot: commandRoot,
                requireExistingPair: true,
                pathPolicy: pathPolicy,
                fileManager: fileManager
            )
        }

        if isXCTest {
            guard let rawRoot = normalizedValues.first else {
                return valid(
                    requested: .xctest,
                    classification: .xctestInMemory,
                    reason: .xctestInMemorySelected,
                    outcome: .notRequired,
                    rootURL: nil
                )
            }
            return diskPlan(
                requested: .xctest,
                classification: .xctestIsolatedDisk,
                successReason: .xctestIsolatedDiskSelected,
                rawRoot: rawRoot,
                requireExistingPair: false,
                pathPolicy: pathPolicy,
                fileManager: fileManager
            )
        }

        if !allRootValues.isEmpty {
            return invalid(requested: .unspecifiedIsolation, reason: .rootWithoutMode)
        }
        return valid(
            requested: .production,
            classification: .production,
            reason: .productionSelected,
            outcome: .notRequired,
            rootURL: nil
        )
    }

    static func encodedEvidence(_ evidence: LokiLaunchStorageEvidence) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(evidence) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func parse(arguments: [String]) -> ParsedArguments {
        var parsed = ParsedArguments()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == signedSmokeSentinel {
                parsed.signedSmokeCount += 1
            } else if argument == isolatedRootArgument {
                let valueIndex = index + 1
                guard valueIndex < arguments.count,
                      !arguments[valueIndex].hasPrefix("--")
                else {
                    parsed.malformed = true
                    index += 1
                    continue
                }
                parsed.rootValues.append(arguments[valueIndex])
                index = valueIndex
            } else if argument.hasPrefix(signedSmokeSentinel + "=")
                        || argument.hasPrefix(isolatedRootArgument + "=") {
                parsed.malformed = true
            }
            index += 1
        }
        return parsed
    }

    private static func diskPlan(
        requested: LokiLaunchStorageRequestedMode,
        classification: LokiLaunchStorageClassification,
        successReason: LokiLaunchStorageReasonCode,
        rawRoot: String,
        requireExistingPair: Bool,
        pathPolicy: LokiLaunchStoragePathPolicy,
        fileManager: FileManager
    ) -> LokiLaunchStoragePlan {
        switch validateRoot(
            rawRoot,
            requireExistingPair: requireExistingPair,
            pathPolicy: pathPolicy,
            fileManager: fileManager
        ) {
        case let .success(rootURL):
            return valid(
                requested: requested,
                classification: classification,
                reason: successReason,
                outcome: .valid,
                rootURL: rootURL
            )
        case let .failure(reason):
            return invalid(requested: requested, reason: reason)
        }
    }

    private static func valid(
        requested: LokiLaunchStorageRequestedMode,
        classification: LokiLaunchStorageClassification,
        reason: LokiLaunchStorageReasonCode,
        outcome: LokiLaunchStorageValidationOutcome,
        rootURL: URL?
    ) -> LokiLaunchStoragePlan {
        let swiftDataURL = rootURL?.appendingPathComponent("LokiBrief-v1.store")
        let vaultURL = rootURL?
            .appendingPathComponent("Vault", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("loki-vault.sqlite3")
        return LokiLaunchStoragePlan(
            classification: classification,
            rootURL: rootURL,
            swiftDataURL: swiftDataURL,
            vaultURL: vaultURL,
            reasonCode: reason,
            evidence: LokiLaunchStorageEvidence(
                status: "success",
                reasonCode: reason.rawValue,
                requestedLaunchMode: requested.rawValue,
                resolvedStorageClassification: classification.rawValue,
                validationOutcome: outcome.rawValue,
                swiftDataVaultPaired: true
            )
        )
    }

    private static func invalid(
        requested: LokiLaunchStorageRequestedMode,
        reason: LokiLaunchStorageReasonCode
    ) -> LokiLaunchStoragePlan {
        LokiLaunchStoragePlan(
            classification: .invalidIsolationIntent,
            rootURL: nil,
            swiftDataURL: nil,
            vaultURL: nil,
            reasonCode: reason,
            evidence: LokiLaunchStorageEvidence(
                status: "failed",
                reasonCode: reason.rawValue,
                requestedLaunchMode: requested.rawValue,
                resolvedStorageClassification: LokiLaunchStorageClassification.invalidIsolationIntent.rawValue,
                validationOutcome: LokiLaunchStorageValidationOutcome.invalid.rawValue,
                swiftDataVaultPaired: false
            )
        )
    }

    private static func validateRoot(
        _ rawRoot: String,
        requireExistingPair: Bool,
        pathPolicy: LokiLaunchStoragePathPolicy,
        fileManager: FileManager
    ) -> Result<URL, LokiLaunchStorageReasonCode> {
        let trimmed = rawRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.rootEmpty) }
        guard NSString(string: trimmed).isAbsolutePath else { return .failure(.rootRelative) }

        let candidate = URL(
            fileURLWithPath: trimmed,
            isDirectory: true
        ).standardizedFileURL
        let lowercasedPath = candidate.path.lowercased()
        if lowercasedPath == "/volumes"
            || lowercasedPath.hasPrefix("/volumes/") {
            return .failure(.rootExternalVolume)
        }
        if lowercasedPath.contains("/backups.backupdb/")
            || lowercasedPath.contains("/.mobilebackups/")
            || lowercasedPath.contains("/.snapshot/")
            || lowercasedPath.contains("/.snapshots/")
            || lowercasedPath.contains("com.apple.timemachine") {
            return .failure(.rootBackupOrSnapshot)
        }
        if isEqualOrDescendant(candidate, of: pathPolicy.productionApplicationSupportRoot) {
            return .failure(.rootProductionContainer)
        }
        if pathPolicy.recoveryRoots.contains(where: { isEqualOrDescendant(candidate, of: $0) }) {
            return .failure(.rootRecoverySource)
        }
        let productionStoreNames: Set<String> = [
            "LokiBrief-v1.store",
            "LokiBrief-v1.store-wal",
            "LokiBrief-v1.store-shm",
        ]
        if candidate.pathComponents.contains(where: productionStoreNames.contains) {
            return .failure(.rootProductionStoreFilename)
        }

        let approvedRoots = pathPolicy.approvedTemporaryRoots.map {
            (
                standardized: $0.standardizedFileURL,
                resolved: $0.resolvingSymlinksInPath().standardizedFileURL
            )
        }
        guard let approved = approvedRoots.first(where: {
            isStrictDescendant(candidate, of: $0.standardized)
                || isStrictDescendant(candidate, of: $0.resolved)
        }) else {
            return .failure(.rootOutsideTemporaryDirectory)
        }

        let pathAnchor = isStrictDescendant(candidate, of: approved.standardized)
            ? approved.standardized
            : approved.resolved
        if containsSymlink(
            between: pathAnchor,
            and: candidate,
            fileManager: fileManager
        ) {
            return .failure(.rootSymlinkEscape)
        }

        let parent = candidate.deletingLastPathComponent()
        var parentIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory) else {
            return .failure(.rootParentMissing)
        }
        guard parentIsDirectory.boolValue else { return .failure(.rootParentNotDirectory) }

        var candidateIsDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: candidate.path, isDirectory: &candidateIsDirectory),
           !candidateIsDirectory.boolValue {
            return .failure(.rootNotDirectory)
        }

        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard approvedRoots.contains(where: { isStrictDescendant(resolved, of: $0.resolved) }) else {
            return .failure(.rootSymlinkEscape)
        }
        do {
            let volumeValues = try parent.resourceValues(
                forKeys: [.volumeIsInternalKey, .volumeIsLocalKey]
            )
            if volumeValues.volumeIsInternal == false || volumeValues.volumeIsLocal == false {
                return .failure(.rootExternalVolume)
            }
        } catch {
            return .failure(.rootUnavailable)
        }

        if requireExistingPair {
            var rootIsDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: resolved.path, isDirectory: &rootIsDirectory),
                  rootIsDirectory.boolValue
            else { return .failure(.rootNotDirectory) }
            let storeURL = resolved.appendingPathComponent("LokiBrief-v1.store")
            let vaultURL = resolved
                .appendingPathComponent("Vault", isDirectory: true)
                .appendingPathComponent("v1", isDirectory: true)
                .appendingPathComponent("loki-vault.sqlite3")
            guard isOrdinaryNonSymlinkFile(storeURL, fileManager: fileManager) else {
                return .failure(.signedSmokeStoreMissing)
            }
            guard isOrdinaryNonSymlinkFile(vaultURL, fileManager: fileManager) else {
                return .failure(.signedSmokeVaultMissing)
            }
        }
        return .success(resolved)
    }

    private static func isOrdinaryNonSymlinkFile(
        _ url: URL,
        fileManager: FileManager
    ) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular
        else { return false }
        return attributes[.type] as? FileAttributeType != .typeSymbolicLink
    }

    private static func containsSymlink(
        between root: URL,
        and candidate: URL,
        fileManager: FileManager
    ) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        guard candidateComponents.starts(with: rootComponents) else { return false }
        var current = root.standardizedFileURL
        for component in candidateComponents.dropFirst(rootComponents.count) {
            current.appendPathComponent(component)
            guard let attributes = try? fileManager.attributesOfItem(atPath: current.path) else {
                continue
            }
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                return true
            }
        }
        return false
    }

    private static func isEqualOrDescendant(_ candidate: URL, of root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private static func isStrictDescendant(_ candidate: URL, of root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return candidatePath != rootPath && candidatePath.hasPrefix(rootPath + "/")
    }
}

private enum LokiLaunchStorageLogger {
    private static let logger = Logger(
        subsystem: "com.agentloki.LokiBrief",
        category: "persistence-selection"
    )

    static func emit(_ evidence: LokiLaunchStorageEvidence) {
        guard let encoded = LokiLaunchStorageResolver.encodedEvidence(evidence) else {
            logger.error(
                "{\"event\":\"persistence_store_selection\",\"status\":\"failed\",\"reason_code\":\"persistence_selection_encoding_failed\"}"
            )
            return
        }
        if evidence.status == "failed" {
            logger.error("\(encoded, privacy: .public)")
        } else {
            logger.notice("\(encoded, privacy: .public)")
        }
    }
}

enum OllamaRuntimeSynchronizationTrigger: String, Codable, Sendable {
    case startup
    case manual
}

struct OllamaRuntimeSynchronizationEvent: Codable, Sendable {
    let event = "ollama_runtime_synchronization"
    let traceID: String
    let spanID: String
    let parentSpanID: String?
    let component = "app_model"
    let status: OllamaTraceStatus
    let reasonCode: String
    let durationMilliseconds: Int?
    let trigger: OllamaRuntimeSynchronizationTrigger

    enum CodingKeys: String, CodingKey {
        case event
        case traceID = "trace_id"
        case spanID = "span_id"
        case parentSpanID = "parent_span_id"
        case component
        case status
        case reasonCode = "reason_code"
        case durationMilliseconds = "duration_ms"
        case trigger
    }
}

typealias OllamaRuntimeSynchronizationSink =
    @Sendable (OllamaRuntimeSynchronizationEvent) -> Void

private enum OllamaRuntimeSynchronizationLogger {
    private static let logger = Logger(
        subsystem: "com.agentloki.LokiBrief",
        category: "ollama-runtime"
    )

    static func emit(_ event: OllamaRuntimeSynchronizationEvent) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(event),
              let line = String(data: data, encoding: .utf8)
        else { return }
        switch event.status {
        case .failed:
            logger.error("\(line, privacy: .public)")
        case .degraded:
            logger.warning("\(line, privacy: .public)")
        default:
            logger.info("\(line, privacy: .public)")
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var selection: NavigationDestination = .today
    @Published private(set) var brief: Brief
    @Published private(set) var briefPresentationContext: BriefPresentationContext = .today
    @Published private(set) var revision = 1
    @Published private(set) var historyCount = 0
    @Published private(set) var history: [BriefHistoryEntry] = []
    @Published private(set) var density: BriefingDensity
    @Published var errorMessage: String?
    @Published private(set) var sources: [BriefSource]
    @Published private(set) var providers: [ModelProvider]
    @Published private(set) var subscriptions: [FeedSubscription] = []
    @Published private(set) var refreshState: FeedRefreshState = .idle
    @Published private(set) var sourceRefreshStates: [String: FeedRefreshState] = [:]
    @Published private(set) var refreshMessage = "Feeds refresh manually or through an enabled Delivery schedule while Loki Brief is running."
    @Published private(set) var localModels: [OllamaModelDescriptor] = []
    @Published private(set) var ollamaStatus = OllamaProviderStatusSnapshot(state: .disabled, checkedAt: nil, discoveredModelCount: 0, selectedModelID: nil, lastFailureCode: nil)
    @Published private(set) var selectedModelID: String?
    @Published private(set) var localGenerationEnabled = false
    @Published private(set) var localGenerationMessage = "Deterministic summaries are active. Ollama is optional."
    @Published private(set) var lastLocalGenerationAt: Date?
    @Published private(set) var settings: StoredSettings
    @Published private(set) var p2Settings: StoredP2Settings
    @Published private(set) var p5Controller: P5DeliveryController? = nil
    @Published private(set) var chatController: LokiChatController? = nil

    let engine: any BriefingEngine
    let store: LocalStore
    let feedClient: any FeedRetrieving
    let feedEngine: DeterministicFeedBriefingEngine
    let mixedEngine: DeterministicMixedBriefingEngine
    let ollamaProvider: NativeOllamaProvider
    let slackController: SlackAppController
    let vaultController: VaultController
    let connectorSourcesController: ConnectorSourcesController
    private let signedSmokeDependencyPackage:
        P8FSignedSmokeDependencyPackage?
    private let currentCivilDayProvider: () -> LocalCalendarDay
    private var refreshTask: Task<Void, Never>?
    private var activeRefreshOperationID: UUID?
    private var activeRefreshSubscriptionIDs: Set<String> = []
    private var activeAddFeedOperationID: UUID?
    private var activeFeedCancellationCleanupID: UUID?
    private var ollamaTask: Task<Void, Never>?
    private var activeOllamaSynchronizationTrigger: OllamaRuntimeSynchronizationTrigger?
    private var ollamaCancellationDrainTask: Task<Void, Never>?
    private var ollamaCancellationDrainID: UUID?
    private let ollamaSynchronizationEventSink: OllamaRuntimeSynchronizationSink
    private var activeOllamaSelection: OllamaModelSelection?
    private var vaultBootstrapTask: Task<Void, Never>?
    private var dataEpoch: UInt64 = 0
    private var ollamaEpoch: UInt64 = 0
    @Published private(set) var updateInstallationInProgress = false
    @Published private(set) var deleteAllInProgress = false

    var hasUpdateBlockingRuntimeWork: Bool {
        updateInstallationInProgress
            || deleteAllInProgress
            || refreshTask != nil
            || activeAddFeedOperationID != nil
            || activeFeedCancellationCleanupID != nil
            || ollamaTask != nil
            || ollamaCancellationDrainTask != nil
            || (chatController?.hasUpdateBlockingWork ?? false)
            || (p5Controller?.hasUpdateBlockingWork ?? false)
            || slackController.hasUpdateBlockingWork
            || vaultController.hasUpdateBlockingWork
            || connectorSourcesController.hasUpdateBlockingWork
    }

    convenience init(
        store: LocalStore,
        engine: any BriefingEngine = DeterministicBriefingEngine(),
        feedClient: any FeedRetrieving = FeedRetrievalClient(),
        feedEngine: DeterministicFeedBriefingEngine = .init(),
        mixedEngine: DeterministicMixedBriefingEngine = .init(),
        ollamaProvider: NativeOllamaProvider = .init(),
        ollamaSynchronizationEventSink:
            OllamaRuntimeSynchronizationSink? = nil,
        slackController: SlackAppController? = nil,
        vaultController: VaultController? = nil,
        currentCivilDayProvider: (() -> LocalCalendarDay)? = nil,
        synchronizeOllamaOnLaunch: Bool = true
    ) throws {
        try self.init(
            signedSmokePackageConstruction: nil,
            store: store,
            engine: engine,
            feedClient: feedClient,
            feedEngine: feedEngine,
            mixedEngine: mixedEngine,
            ollamaProvider: ollamaProvider,
            ollamaSynchronizationEventSink:
                ollamaSynchronizationEventSink,
            slackController: slackController,
            vaultController: vaultController,
            currentCivilDayProvider: currentCivilDayProvider,
            synchronizeOllamaOnLaunch: synchronizeOllamaOnLaunch
        )
    }

    private init(
        signedSmokePackageConstruction:
            P8FSignedSmokeDependencyPackage?,
        store: LocalStore,
        engine: any BriefingEngine,
        feedClient: any FeedRetrieving,
        feedEngine: DeterministicFeedBriefingEngine,
        mixedEngine: DeterministicMixedBriefingEngine,
        ollamaProvider: NativeOllamaProvider,
        ollamaSynchronizationEventSink:
            OllamaRuntimeSynchronizationSink?,
        slackController: SlackAppController?,
        vaultController: VaultController?,
        currentCivilDayProvider: (() -> LocalCalendarDay)?,
        synchronizeOllamaOnLaunch: Bool
    ) throws {
        let signedSmokeDependencyPackage =
            signedSmokePackageConstruction
        let signedSmokeStorageBoundary =
            signedSmokeDependencyPackage?.admittedStorageBoundary
        let signedSmokeRuntimeAuthority =
            signedSmokeDependencyPackage?.admittedRuntimeAuthority
        self.store = store
        self.engine = engine
        self.feedClient = feedClient
        self.feedEngine = feedEngine
        self.mixedEngine = mixedEngine
        self.ollamaProvider = ollamaProvider
        self.ollamaSynchronizationEventSink = ollamaSynchronizationEventSink
            ?? { OllamaRuntimeSynchronizationLogger.emit($0) }
        self.signedSmokeDependencyPackage =
            signedSmokeDependencyPackage
        self.currentCivilDayProvider = currentCivilDayProvider ?? {
            LocalCalendarDay.resolve(containing: Date())
        }
        let resolvedSlackController: SlackAppController
        let resolvedVaultController: VaultController
        if let signedSmokeStorageBoundary {
            guard let signedSmokeRuntimeAuthority,
                  let signedSmokeDependencyPackage,
                  let slackController,
                  let vaultController
            else {
                throw SemanticIndexFailureCode
                    .signedSmokeAuthorityInvalid
            }
            try signedSmokeDependencyPackage
                .validateApplicationDependencies(
                    store: store,
                    slackController: slackController,
                    vaultController: vaultController,
                    storageBoundary: signedSmokeStorageBoundary,
                    runtimeAuthority: signedSmokeRuntimeAuthority
                )
            resolvedSlackController = slackController
            resolvedVaultController = vaultController
        } else {
            guard signedSmokeDependencyPackage == nil else {
                throw SemanticIndexFailureCode
                    .signedSmokeAuthorityInvalid
            }
            resolvedSlackController = slackController
                ?? SlackAppController(
                    store: store,
                    eventSink: {
                        @Sendable event in
                        SlackProductionTraceLogger.emit(event)
                    }
                )
            resolvedVaultController = try vaultController
                ?? VaultController(
                    store: store,
                    slackController: resolvedSlackController
                )
        }
        self.slackController = resolvedSlackController
        self.vaultController = resolvedVaultController
        self.connectorSourcesController = ConnectorSourcesController(
            store: store,
            vaultController: resolvedVaultController
        )
        let loadedSettings = try store.settings()
        let loadedP2Settings = try store.p2Settings()
        if loadedP2Settings.previewFixturesEnabled {
            loadedP2Settings.previewFixturesEnabled = false
            try store.save()
        }
        self.settings = loadedSettings
        self.p2Settings = loadedP2Settings
        self.density = loadedSettings.density
        let launchBrief: Brief
        if loadedP2Settings.previewFixturesEnabled {
            launchBrief = engine.generatePreview(revision: 1)
        } else if let currentCivilDayProvider {
            launchBrief = feedEngine.assemble(
                entries: [],
                subscriptions: [],
                preferences: .default,
                briefingDay: currentCivilDayProvider()
            ).brief
        } else {
            // Respect an injected deterministic engine clock in existing tests.
            // Production's default engine resolves through the current calendar
            // and time zone at this same boundary.
            launchBrief = feedEngine.assemble(
                entries: [],
                subscriptions: [],
                preferences: .default
            ).brief
        }
        self.brief = launchBrief
        self.sources = FoundationCatalog.sources
        self.providers = FoundationCatalog.providers
        self.subscriptions = try store.domainFeedSubscriptions()
        self.localModels = try store.domainLocalModels()
        let modelSelection = try store.modelSelection()
        self.selectedModelID = modelSelection.modelID
        self.localGenerationEnabled = modelSelection.localGenerationEnabled && !loadedSettings.deterministicOnly
        let persistedProviderSnapshot = try store.providerSnapshot()
        if let snapshot = persistedProviderSnapshot {
            let previousFailure = snapshot.failureCode.flatMap(OllamaFailureCode.init(rawValue:))
            self.ollamaStatus = .init(
                state: .disabled,
                checkedAt: snapshot.checkedAt,
                lastSuccessfulCheckAt: snapshot.lastSuccessfulCheckAt,
                discoveredModelCount: self.localModels.count,
                selectedModelID: nil,
                lastFailureCode: previousFailure
            )
            if let message = snapshot.failureMessage, !message.isEmpty {
                self.localGenerationMessage = "Ollama remains disabled until you check it. Previous check: \(message)"
            } else if let version = snapshot.serviceVersion, !version.isEmpty {
                self.localGenerationMessage = "Ollama remains disabled until you check it. Last observed version: \(version)."
            }
        }
        if let latestGeneration = try store.latestSuccessfulLocalGenerationProvenance() {
            self.lastLocalGenerationAt = latestGeneration.generatedAt
        }
        applyReadStates()
        try reloadHistory()
        let launchDay = launchBrief.resolvedBriefingDay
        if let decoded = try store.history()
            .lazy
            .filter({ $0.statusRaw != BriefStatus.preview.rawValue })
            .compactMap({ try? $0.decodedBrief() })
            .first(where: { $0.resolvedBriefingDay == launchDay }) {
            self.brief = decoded
            applyReadStates()
        }
        rebuildCatalogs()
        self.slackController.onBriefingEvidenceChanged = { [weak self] failureNotes in
            guard let self else { return }
            await self.vaultController.reconcileExistingEvidence()
            await self.rebuildBriefAfterSlackChange(failureNotes: failureNotes)
        }
        self.slackController.onSlackEvidenceDeletionWillBegin = {
            [weak self] _, _ in
            guard let self else { return }
            self.cancelSlackLocalGeneration()
            await self.chatController?.prepareForExternalEvidenceDeletion()
        }
        self.slackController.onSlackEvidenceDeletionCompleted = {
            [weak self] workspaceID, channelID in
            await self?.chatController?.completeExternalEvidenceDeletion(
                sourceKind: .slack,
                accountIdentifier: workspaceID,
                containerIdentifier: channelID
            )
        }
        if signedSmokeDependencyPackage == nil {
            do {
                self.p5Controller = try P5DeliveryController(
                    model: self,
                    store: store
                )
            } catch {
                self.p5Controller = nil
                self.errorMessage = "Scheduled delivery is unavailable for this launch: \(error.localizedDescription)"
            }
        } else {
            // Signed-smoke has no scheduling, notification, connector, or
            // publication authority. Omitting P5 is the fail-closed runtime
            // contract rather than constructing live defaults and hoping they
            // remain unused.
            self.p5Controller = nil
        }
        do {
            self.chatController = try LokiChatController(
                model: self,
                store: store,
                signedSmokeStorageBoundary:
                    signedSmokeStorageBoundary,
                signedSmokeRuntimeAuthority:
                    signedSmokeRuntimeAuthority,
                signedSmokeDependencyPackage:
                    signedSmokeDependencyPackage
            )
        } catch {
            if signedSmokeDependencyPackage != nil {
                throw error
            }
            self.chatController = nil
            self.errorMessage = "Agent Loki Chat is unavailable for this launch; Loki Brief remains usable. \(error.localizedDescription)"
        }
        self.connectorSourcesController.attachedDataSourcesController
            .configureSemanticAuthorityChangeHandler { [weak self] reasonCode in
                guard let chatController = self?.chatController else {
                    return AttachedDataSemanticAuthorityTransaction.denied()
                }
                return chatController.beginAttachedSourceSemanticAuthorityChange(
                    reasonCode: reasonCode
                )
            }
        self.vaultController.onEvidenceDeletionWillBegin = { [weak self] in
            await self?.chatController?.prepareForExternalEvidenceDeletion()
        }
        self.vaultController.onEvidenceDeletionCompleted = { [weak self] accountID in
            await self?.chatController?.completeExternalEvidenceDeletion(
                sourceKind: .vault,
                accountIdentifier: accountID
            )
        }
        self.vaultBootstrapTask = Task { [weak self] in
            guard let self else { return }
            await self.vaultController.bootstrap()
            self.vaultBootstrapTask = nil
        }
        if signedSmokeDependencyPackage == nil,
           synchronizeOllamaOnLaunch,
           Self.shouldSynchronizeOllamaOnLaunch(
               from: persistedProviderSnapshot
           ) {
            startOllamaSynchronization(trigger: .startup)
        }
    }

    static func live(
        isTesting: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil,
        isolatedTestDataRoot explicitTestDataRoot: URL? = nil,
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        pathPolicy: LokiLaunchStoragePathPolicy = .live()
    ) -> AppModel {
        do {
            return try makeLive(
                isTesting: isTesting,
                isolatedTestDataRoot: explicitTestDataRoot,
                arguments: arguments,
                environment: environment,
                pathPolicy: pathPolicy
            )
        } catch let reason as LokiLaunchStorageReasonCode {
            fatalError("Unable to select a safe Loki Brief persistence store: \(reason.rawValue)")
        } catch {
            fatalError("Unable to construct the selected Loki Brief persistence store.")
        }
    }

    static func makeLive(
        isTesting: Bool,
        isolatedTestDataRoot explicitTestDataRoot: URL? = nil,
        arguments: [String],
        environment: [String: String],
        pathPolicy: LokiLaunchStoragePathPolicy = .live(),
        fileManager: FileManager = .default
    ) throws -> AppModel {
        let plan = LokiLaunchStorageResolver.resolve(
            arguments: arguments,
            environment: environment,
            isXCTest: isTesting,
            explicitTestDataRoot: explicitTestDataRoot,
            pathPolicy: pathPolicy,
            fileManager: fileManager
        )
        LokiLaunchStorageLogger.emit(plan.evidence)
        guard plan.isValid else { throw plan.reasonCode }

        switch plan.classification {
        case .production:
            do {
                return try AppModel(store: LocalStore())
            } catch {
                let fallback = try makeInMemoryModel()
                fallback.errorMessage = "Local persistence is unavailable. Loki Brief is using a temporary preview store for this launch. The existing store was not reset. \(String(error.localizedDescription.prefix(500)))"
                return fallback
            }
        case .xctestInMemory:
            return try makeInMemoryModel()
        case .xctestIsolatedDisk:
            return try makeIsolatedDiskModel(
                plan: plan,
                createDestination: true,
                fileManager: fileManager
            )
        case .signedSmokeIsolatedDisk:
            // A storage-shaped command line is not signed-smoke admission.
            // Only makeAdmittedSignedSmoke may supply the opaque runtime
            // authority and coherent dependency package.
            throw LokiLaunchStorageReasonCode.signedSmokePairInvalid
        case .invalidIsolationIntent:
            throw plan.reasonCode
        }
    }

    static func makeAdmittedSignedSmoke(
        _ admission: P8FSignedSmokeAdmission,
        fileManager: FileManager = .default
    ) throws -> AppModel {
        let plan = admission.storagePlan
        guard plan.isValid,
              plan.classification == .signedSmokeIsolatedDisk
        else {
            throw LokiLaunchStorageReasonCode
                .signedSmokePairInvalid
        }
        LokiLaunchStorageLogger.emit(plan.evidence)
        let model = try makeIsolatedDiskModel(
            plan: plan,
            createDestination: false,
            signedSmokeStorageBoundary:
                admission.storageBoundary,
            signedSmokeRuntimeAuthority:
                admission.runtimeAuthority,
            fileManager: fileManager
        )
        guard let features = model.chatController?.p8Features,
              features
                .declareSignedSmokeWebCredentialAbsentWithoutRead()
        else {
            throw P8FSignedSmokeCoordinatorFailure
                .prerequisiteMissing
        }
        return model
    }

    /// The sole application-construction route for an admitted signed-smoke
    /// dependency package. Every behavior-capable dependency is selected by
    /// the package, and launch-time Ollama synchronization is unconditionally
    /// disabled.
    static func makeSignedSmokeApplication(
        using dependencyPackage: P8FSignedSmokeDependencyPackage
    ) throws -> AppModel {
        let store = dependencyPackage.admittedApplicationStore
        guard let slackController =
                dependencyPackage.applicationSlackController,
              let vaultController =
                dependencyPackage.applicationVaultController
        else {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
        try dependencyPackage.validateApplicationDependencies(
            store: store,
            slackController: slackController,
            vaultController: vaultController,
            storageBoundary:
                dependencyPackage.admittedStorageBoundary,
            runtimeAuthority:
                dependencyPackage.admittedRuntimeAuthority
        )
        return try AppModel(
            signedSmokePackageConstruction: dependencyPackage,
            store: store,
            engine: dependencyPackage.applicationBriefingEngine,
            feedClient: dependencyPackage.applicationFeedClient,
            feedEngine: dependencyPackage.applicationFeedEngine,
            mixedEngine: dependencyPackage.applicationMixedEngine,
            ollamaProvider: dependencyPackage.applicationOllamaProvider,
            ollamaSynchronizationEventSink:
                dependencyPackage
                    .applicationOllamaSynchronizationEventSink,
            slackController: slackController,
            vaultController: vaultController,
            currentCivilDayProvider:
                dependencyPackage.applicationCurrentCivilDayProvider,
            synchronizeOllamaOnLaunch: false
        )
    }

    /// Returns only the exact application-owned package retained during
    /// admitted signed-smoke construction, after revalidating its complete
    /// application dependency graph against the active admission authority.
    func retainedSignedSmokeDependencyPackage(
        storageBoundary: P8FSignedSmokeStorageBoundary,
        runtimeAuthority: P8FSignedSmokeRuntimeAuthority
    ) throws -> P8FSignedSmokeDependencyPackage {
        guard let signedSmokeDependencyPackage else {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
        try signedSmokeDependencyPackage
            .validateApplicationDependencies(
                store: store,
                slackController: slackController,
                vaultController: vaultController,
                storageBoundary: storageBoundary,
                runtimeAuthority: runtimeAuthority
            )
        return signedSmokeDependencyPackage
    }

    private static func makeInMemoryModel() throws -> AppModel {
        let store = try LocalStore(inMemory: true)
        let slackController = SlackAppController(
            store: store,
            clientID: nil,
            credentialStore: VolatileSlackCredentialStore(),
            eventSink: { @Sendable event in SlackProductionTraceLogger.emit(event) }
        )
        let vaultController = try VaultController(
            store: store,
            slackController: slackController,
            inMemory: true
        )
        return try AppModel(
            store: store,
            feedClient: DisabledFeedClient(),
            slackController: slackController,
            vaultController: vaultController
        )
    }

    private static func makeIsolatedDiskModel(
        plan: LokiLaunchStoragePlan,
        createDestination: Bool,
        signedSmokeStorageBoundary:
            P8FSignedSmokeStorageBoundary? = nil,
        signedSmokeRuntimeAuthority:
            P8FSignedSmokeRuntimeAuthority? = nil,
        fileManager: FileManager
    ) throws -> AppModel {
        guard let rootURL = plan.rootURL,
              let swiftDataURL = plan.swiftDataURL,
              let vaultURL = plan.vaultURL
        else { throw LokiLaunchStorageReasonCode.signedSmokePairInvalid }

        if createDestination {
            if !fileManager.fileExists(atPath: rootURL.path) {
                try fileManager.createDirectory(
                    at: rootURL,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            try fileManager.createDirectory(
                at: vaultURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        if let signedSmokeStorageBoundary {
            try signedSmokeStorageBoundary.validateCurrentRoot(
                fileManager: fileManager
            )
            try signedSmokeStorageBoundary.validateSQLiteFamily(
                at: swiftDataURL,
                requireDatabase: true,
                fileManager: fileManager
            )
            try signedSmokeStorageBoundary.validateSQLiteFamily(
                at: vaultURL,
                requireDatabase: true,
                fileManager: fileManager
            )
        }
        let store = try LocalStore(url: swiftDataURL)
        try signedSmokeStorageBoundary?.secureSQLiteFamily(
            at: swiftDataURL,
            requireDatabase: true,
            fileManager: fileManager
        )
        let signedSmokeDependencyPackage:
            P8FSignedSmokeDependencyPackage?
        let slackController: SlackAppController
        let vaultController: VaultController
        if let signedSmokeStorageBoundary {
            guard let signedSmokeRuntimeAuthority else {
                throw SemanticIndexFailureCode
                    .signedSmokeAuthorityInvalid
            }
            let dependencyPackage = try P8FSignedSmokeDependencyPackage
                .makeApplicationOwned(
                    store: store,
                    vaultDatabaseURL: vaultURL,
                    storageBoundary: signedSmokeStorageBoundary,
                    runtimeAuthority: signedSmokeRuntimeAuthority
                )
            guard let admittedSlack =
                    dependencyPackage.applicationSlackController,
                  let admittedVault =
                    dependencyPackage.applicationVaultController
            else {
                throw SemanticIndexFailureCode
                    .signedSmokeAuthorityInvalid
            }
            signedSmokeDependencyPackage = dependencyPackage
            slackController = admittedSlack
            vaultController = admittedVault
        } else {
            signedSmokeDependencyPackage = nil
            slackController = SlackAppController(
                store: store,
                clientID: nil,
                credentialStore: VolatileSlackCredentialStore(),
                eventSink: {
                    @Sendable event in
                    SlackProductionTraceLogger.emit(event)
                }
            )
            vaultController = try VaultController(
                store: store,
                slackController: slackController,
                databaseURL: vaultURL
            )
        }
        try signedSmokeStorageBoundary?.secureSQLiteFamily(
            at: vaultURL,
            requireDatabase: true,
            fileManager: fileManager
        )
        if signedSmokeStorageBoundary != nil {
            let expectedRoot = LokiCanonicalFileURL.lexical(
                rootURL,
                isDirectory: true
            )
            let expectedSwiftData = LokiCanonicalFileURL.lexical(
                swiftDataURL
            )
            let expectedVault = LokiCanonicalFileURL.lexical(vaultURL)
            guard let openedSwiftData = store.storageURL.flatMap({
                    LokiCanonicalFileURL.existing(
                        $0,
                        isDirectory: false
                    )
                  }),
                  let openedVault = LokiCanonicalFileURL.existing(
                    vaultController.databaseURL,
                    isDirectory: false
                  ),
                  openedSwiftData == expectedSwiftData,
                  openedVault == expectedVault,
                  openedSwiftData.deletingLastPathComponent()
                    == expectedRoot,
                  openedVault.path.hasPrefix(expectedRoot.path + "/")
            else {
                throw LokiLaunchStorageReasonCode.signedSmokePairInvalid
            }
        } else {
            guard store.storageURL
                    == swiftDataURL.resolvingSymlinksInPath()
                        .standardizedFileURL,
                  vaultController.databaseURL
                    == vaultURL.resolvingSymlinksInPath()
                        .standardizedFileURL,
                  store.storageURL?.deletingLastPathComponent()
                    == rootURL,
                  vaultController.databaseURL.path.hasPrefix(
                    rootURL.path + "/"
                  )
            else {
                throw LokiLaunchStorageReasonCode.signedSmokePairInvalid
            }
        }
        let model: AppModel
        if let signedSmokeDependencyPackage {
            model = try makeSignedSmokeApplication(
                using: signedSmokeDependencyPackage
            )
        } else {
            model = try AppModel(
                store: store,
                feedClient: DisabledFeedClient(),
                slackController: slackController,
                vaultController: vaultController,
                synchronizeOllamaOnLaunch: true
            )
        }
        try signedSmokeStorageBoundary?.secureSQLiteFamily(
            at: swiftDataURL,
            requireDatabase: true,
            fileManager: fileManager
        )
        try signedSmokeStorageBoundary?.secureSQLiteFamily(
            at: vaultURL,
            requireDatabase: true,
            fileManager: fileManager
        )
        return model
    }

    func addFeed(urlText: String, title: String, saveWhenUnavailable: Bool) async -> Bool {
        guard allowPersistenceMutationDuringUpdate() else { return false }
        guard refreshTask == nil, activeAddFeedOperationID == nil, activeFeedCancellationCleanupID == nil else { errorMessage = "Wait for the current feed operation to finish or cancel it."; return false }
        let operationEpoch = dataEpoch
        let normalizedURLText = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedURLText.isEmpty, normalizedURLText.count <= FeedLimits.maximumURLCharacters,
              let rawURL = URL(string: normalizedURLText),
              let canonicalInputURL = FeedSubscription.syntacticallyCanonicalURL(rawURL)
        else { errorMessage = FeedFetchFailure(.invalidURL).message; return false }
        let createdAt = Date()
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let proposedTitle = normalizedTitle.isEmpty ? canonicalInputURL.host ?? "Feed" : normalizedTitle
        let proposed = FeedSubscription(id: FeedSubscription.stableIdentifier(for: canonicalInputURL), title: String(proposedTitle.prefix(FeedLimits.maximumTitleCharacters)), canonicalURL: canonicalInputURL, enabled: true, format: .unknown, lastAttemptedAt: nil, lastSuccessfulAt: nil, lastHTTPStatus: nil, eTag: nil, lastModified: nil, state: .validating, failure: nil, policy: .default, weight: 1, createdAt: createdAt, updatedAt: createdAt)
        if subscriptions.contains(where: { $0.id == proposed.id }) { errorMessage = "That feed is already saved."; return false }
        let addOperationID = UUID()
        activeAddFeedOperationID = addOperationID
        defer {
            if activeAddFeedOperationID == addOperationID { activeAddFeedOperationID = nil }
        }
        refreshState = .validating; sourceRefreshStates[proposed.id] = .validating
        let trace = FeedTraceContext()
        do {
            let result = try await feedClient.fetch(proposed, trace: trace, progress: { [weak self] state in
                await self?.applyAddFeedProgress(state, subscriptionID: proposed.id, epoch: operationEpoch, operationID: addOperationID)
            })
            guard dataEpoch == operationEpoch, !Task.isCancelled else { return false }
            if subscriptions.contains(where: { $0.canonicalURL == result.subscription.canonicalURL }) {
                errorMessage = "That canonical feed URL is already saved."
                refreshState = .failed
                return false
            }
            try store.persistFeedFetchResult(result, settings: p2Settings)
            try reloadSubscriptions()
            await vaultController.reconcileExistingEvidence()
            sourceRefreshStates[result.subscription.id] = .complete
            refreshState = .assembling
            await assembleBrief(failureNotes: [], epoch: operationEpoch)
            guard dataEpoch == operationEpoch, !Task.isCancelled else { return false }
            refreshState = .complete; refreshMessage = "Added and refreshed \(result.subscription.title)."
            return true
        } catch {
            guard dataEpoch == operationEpoch, !Task.isCancelled else { return false }
            let failure = (error as? FeedFetchFailure) ?? .init(.networkUnavailable)
            sourceRefreshStates[proposed.id] = .failed
            refreshState = .failed
            let transientUnavailableCodes: Set<FeedFetchFailureCode> = [.networkUnavailable, .requestTimedOut, .unexpectedHTTPStatus]
            if saveWhenUnavailable && transientUnavailableCodes.contains(failure.code) {
                var unavailable = proposed
                unavailable.state = .savedUnavailable; unavailable.failure = failure; unavailable.lastAttemptedAt = Date(); unavailable.updatedAt = Date()
                do { try store.persistFeedSubscription(unavailable); try reloadSubscriptions(); refreshMessage = "Saved — currently unavailable: \(failure.message)"; return true }
                catch { errorMessage = error.localizedDescription; return false }
            }
            errorMessage = failure.message
            return false
        }
    }

    func refreshAllFeeds() {
        startRefresh(subscriptions.filter(\.enabled))
    }

    func refreshFeed(id: String) {
        startRefresh(subscriptions.filter { $0.id == id && $0.enabled })
    }

    private func startRefresh(_ targets: [FeedSubscription]) {
        guard allowPersistenceMutationDuringUpdate() else { return }
        guard refreshTask == nil, activeAddFeedOperationID == nil, activeFeedCancellationCleanupID == nil else { errorMessage = "A feed operation is already in progress."; return }
        guard !targets.isEmpty else { errorMessage = "Enable at least one feed before refreshing."; return }
        let epoch = dataEpoch
        let operationID = UUID()
        activeRefreshOperationID = operationID
        activeRefreshSubscriptionIDs = Set(targets.map(\.id))
        refreshTask = Task { [weak self] in await self?.performRefresh(targets, epoch: epoch, operationID: operationID) }
    }

    private func performRefresh(_ targets: [FeedSubscription], epoch: UInt64, operationID: UUID) async {
        refreshState = .validating
        refreshMessage = "Validating \(targets.count) feed\(targets.count == 1 ? "" : "s")…"
        for target in targets { sourceRefreshStates[target.id] = .validating }
        let client = feedClient
        var outcomes: [FeedRefreshOutcome] = []
        await withTaskGroup(of: FeedRefreshOutcome.self) { group in
            var iterator = targets.makeIterator()
            for _ in 0..<min(FeedLimits.maximumConcurrentRefreshes, targets.count) {
                if let subscription = iterator.next() { addRefresh(subscription, client: client, epoch: epoch, operationID: operationID, to: &group) }
            }
            while let outcome = await group.next() {
                outcomes.append(outcome)
                let operationIsActive = !Task.isCancelled && dataEpoch == epoch && activeRefreshOperationID == operationID
                if operationIsActive {
                    switch outcome {
                    case let .success(result):
                        sourceRefreshStates[result.subscription.id] = .complete
                        activeRefreshSubscriptionIDs.remove(result.subscription.id)
                    case let .failure(subscription, failure, _, _):
                        sourceRefreshStates[subscription.id] = failure.code == .requestCancelled ? .cancelled : .failed
                        activeRefreshSubscriptionIDs.remove(subscription.id)
                    }
                }
                if operationIsActive, let subscription = iterator.next() {
                    addRefresh(subscription, client: client, epoch: epoch, operationID: operationID, to: &group)
                }
            }
        }
        if Task.isCancelled || dataEpoch != epoch {
            if dataEpoch == epoch {
                refreshState = .cancelled; refreshMessage = "Refresh cancelled. The last valid brief was preserved."
                refreshTask = nil
                if activeRefreshOperationID == operationID {
                    for subscriptionID in activeRefreshSubscriptionIDs { sourceRefreshStates[subscriptionID] = .cancelled }
                    activeRefreshSubscriptionIDs.removeAll()
                    activeRefreshOperationID = nil
                }
            }
            return
        }

        var failures: [String] = []
        var successCount = 0
        for outcome in outcomes {
            switch outcome {
            case let .success(result):
                do { try store.persistFeedFetchResult(result, settings: p2Settings); sourceRefreshStates[result.subscription.id] = .complete; successCount += 1 }
                catch { failures.append("\(result.subscription.title): local persistence failed"); sourceRefreshStates[result.subscription.id] = .failed }
            case let .failure(subscription, failure, traceID, failedAt):
                var updated = subscription
                updated.lastAttemptedAt = failedAt; updated.state = .degraded; updated.failure = failure; updated.updatedAt = failedAt
                do {
                    try store.persistFeedSubscription(updated)
                    try store.recordFetch(.init(id: "fetch-\(subscription.id)-\(Int(failedAt.timeIntervalSince1970 * 1_000))-failed", subscriptionID: subscription.id, traceID: traceID, attemptedAt: failedAt, completedAt: failedAt, statusRaw: "failed", httpStatus: failure.httpStatus, failureCode: failure.reasonCode, failureMessage: failure.message))
                } catch { }
                failures.append("\(subscription.title): \(failure.message)")
                sourceRefreshStates[subscription.id] = failure.code == .requestCancelled ? .cancelled : .failed
            }
        }
        do { try reloadSubscriptions() } catch { errorMessage = error.localizedDescription }
        if successCount > 0 {
            await vaultController.reconcileExistingEvidence()
            refreshState = .assembling
            await assembleBrief(failureNotes: failures, epoch: epoch)
            guard dataEpoch == epoch, !Task.isCancelled else { return }
            refreshState = failures.isEmpty ? .complete : .partial
            refreshMessage = failures.isEmpty ? "Refreshed \(successCount) feed\(successCount == 1 ? "" : "s")." : "Partial refresh: \(successCount) succeeded, \(failures.count) failed."
        } else {
            refreshState = failures.allSatisfy { $0.contains("cancel") } ? .cancelled : .failed
            refreshMessage = "No feed refreshed successfully. The last valid brief was preserved."
        }
        refreshTask = nil
        if activeRefreshOperationID == operationID {
            activeRefreshSubscriptionIDs.removeAll()
            activeRefreshOperationID = nil
        }
        rebuildCatalogs()
    }

    private func addRefresh(_ subscription: FeedSubscription, client: any FeedRetrieving, epoch: UInt64, operationID: UUID, to group: inout TaskGroup<FeedRefreshOutcome>) {
        let trace = FeedTraceContext()
        group.addTask { [weak self] in
            do {
                return .success(try await client.fetch(subscription, trace: trace, progress: { [weak self] state in
                    await self?.applyRefreshProgress(state, subscription: subscription, epoch: epoch, operationID: operationID)
                }))
            }
            catch { return .failure(subscription: subscription, failure: (error as? FeedFetchFailure) ?? .init(.networkUnavailable), traceID: trace.traceID, failedAt: Date()) }
        }
    }

    private func applyAddFeedProgress(_ state: FeedRefreshState, subscriptionID: String, epoch: UInt64, operationID: UUID) {
        guard dataEpoch == epoch, activeAddFeedOperationID == operationID, !Task.isCancelled else { return }
        applyVisibleProgress(state, subscriptionID: subscriptionID, title: "feed")
    }

    private func applyRefreshProgress(_ state: FeedRefreshState, subscription: FeedSubscription, epoch: UInt64, operationID: UUID) {
        guard dataEpoch == epoch, activeRefreshOperationID == operationID, refreshTask != nil, !Task.isCancelled else { return }
        applyVisibleProgress(state, subscriptionID: subscription.id, title: subscription.title)
    }

    private func applyVisibleProgress(_ state: FeedRefreshState, subscriptionID: String, title: String) {
        sourceRefreshStates[subscriptionID] = state
        switch state {
        case .validating:
            refreshState = .validating; refreshMessage = "Validating \(title)…"
        case .fetching:
            refreshState = .fetching; refreshMessage = "Fetching \(title)…"
        case .parsing:
            refreshState = .parsing; refreshMessage = "Parsing \(title)…"
        case .normalizing:
            refreshState = .normalizing; refreshMessage = "Normalizing \(title)…"
        default:
            break
        }
    }

    func cancelRefresh() {
        guard refreshTask != nil else { return }
        dataEpoch &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        for subscriptionID in activeRefreshSubscriptionIDs { sourceRefreshStates[subscriptionID] = .cancelled }
        activeRefreshSubscriptionIDs.removeAll()
        activeRefreshOperationID = nil
        refreshState = .cancelled
        refreshMessage = "Refresh cancelled. The last valid brief was preserved."
        beginFeedCancellationCleanup(disableProvider: false)
    }

    private func beginFeedCancellationCleanup(disableProvider: Bool) {
        let cleanupID = UUID()
        activeFeedCancellationCleanupID = cleanupID
        let client = feedClient
        let provider = ollamaProvider
        Task { [weak self] in
            await client.cancelAll()
            if disableProvider { await provider.setEnabled(false) }
            else { await provider.cancelGeneration() }
            guard let self, self.activeFeedCancellationCleanupID == cleanupID else { return }
            self.activeFeedCancellationCleanupID = nil
        }
    }

    func setFeedEnabled(id: String, enabled: Bool) {
        guard allowPersistenceMutationDuringUpdate() else { return }
        guard var subscription = subscriptions.first(where: { $0.id == id }) else { return }
        subscription.enabled = enabled; subscription.state = enabled ? (subscription.lastSuccessfulAt == nil ? .savedUnavailable : .connected) : .disabled; subscription.updatedAt = Date()
        do { try store.persistFeedSubscription(subscription); try reloadSubscriptions(); rebuildCatalogs() }
        catch { errorMessage = error.localizedDescription }
    }

    func updateFeedTitle(id: String, title: String) {
        guard allowPersistenceMutationDuringUpdate() else { return }
        guard var subscription = subscriptions.first(where: { $0.id == id }) else { return }
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        subscription.title = String(normalized.prefix(FeedLimits.maximumTitleCharacters)); subscription.updatedAt = Date()
        do { try store.persistFeedSubscription(subscription); try reloadSubscriptions() }
        catch { errorMessage = error.localizedDescription }
    }

    func updateFeedWeight(id: String, weight: Double) {
        guard allowPersistenceMutationDuringUpdate() else { return }
        guard var subscription = subscriptions.first(where: { $0.id == id }) else { return }
        subscription.weight = min(max(weight, 0.5), 2); subscription.updatedAt = Date()
        do { try store.persistFeedSubscription(subscription); try reloadSubscriptions() }
        catch { errorMessage = error.localizedDescription }
    }

    func removeFeed(id: String) {
        guard allowPersistenceMutationDuringUpdate() else { return }
        guard chatController?.isGenerating != true else {
            errorMessage = "Stop Agent Loki Chat before removing this feed."
            return
        }
        do {
            try store.removeFeedSubscription(id: id)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        do {
            if let chatController {
                try chatController.scrubEvidenceAfterExternalSourceDeletion(
                    sourceKind: .feed,
                    accountIdentifier: id
                )
            } else {
                _ = try store.scrubLokiChatEvidence(
                    sourceKind: .feed,
                    accountIdentifier: id
                )
                _ = try store.scrubLokiChatEvidence(
                    sourceKind: .connectedSourceStatus,
                    accountIdentifier: id,
                    accountClassification: "feed_subscription"
                )
                _ = try store.scrubLokiChatEvidence(
                    sourceKind: .vault,
                    accountIdentifier: nil,
                    accountClassification: VaultProviderKind.rss.rawValue,
                    containerIdentifier: VaultIdentity.containerID(
                        provider: VaultProviderKind.rss.rawValue,
                        accountID: VaultIdentity.accountID(
                            provider: VaultProviderKind.rss.rawValue,
                            providerAccountID: "local-feeds"
                        ),
                        providerContainerID: id
                    )
                )
            }
        } catch {
            let fallbackSucceeded: Bool
            if let chatController {
                fallbackSucceeded =
                    chatController.discardAllConversationsAfterEvidenceScrubFailure()
            } else {
                fallbackSucceeded = (try? store.deleteAllLokiConversations()) != nil
            }
            errorMessage = fallbackSucceeded
                ? "Removed the feed and all local Agent Loki conversations because revoked evidence could not be scrubbed selectively."
                : "The feed was removed, but Agent Loki Chat remains unavailable until revoked evidence cleanup succeeds."
        }
        do {
            try reloadSubscriptions()
            sourceRefreshStates.removeValue(forKey: id)
            rebuildCatalogs()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func assembleBrief(failureNotes: [String], slackFailureNotes: [String] = [], epoch: UInt64) async {
        do {
            guard dataEpoch == epoch, !Task.isCancelled else { return }
            let enabledIDs = Set(subscriptions.filter(\.enabled).map(\.id))
            let entries = try store.domainFeedEntries(enabledSubscriptionIDs: enabledIDs)
            let topics = p2Settings.topicPreferences.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let readStates = try store.readStates()
            let feedResult = feedEngine.assemble(entries: entries, subscriptions: subscriptions, preferences: .init(topicKeywords: topics, sourceWeights: Dictionary(uniqueKeysWithValues: subscriptions.map { ($0.id, $0.weight) }), readStates: readStates, briefingWindowHours: 168, maximumItems: 40), failureNotes: failureNotes)
            let enabledSlackWorkspaceIDs = Set(try store.slackWorkspaceConnections().filter(\.enabled).map(\.id))
            let selectedSlackChannelKeys = try enabledSlackWorkspaceIDs.reduce(into: Set<String>()) { keys, workspaceID in
                for selection in try store.domainSlackSelections(workspaceID: workspaceID) where selection.enabled {
                    keys.insert("\(workspaceID):\(selection.channelID)")
                }
            }
            let slackEvidence = try store.domainSlackEvidence().filter {
                selectedSlackChannelKeys.contains("\($0.workspaceID):\($0.channelID)")
            }
            let result = mixedEngine.assemble(
                feedResult: feedResult,
                slackEvidence: slackEvidence,
                slackPreferences: .init(readStates: readStates, briefingWindowHours: 168, maximumItems: 40, urgencyTerms: SlackBriefingPreferences.default.urgencyTerms),
                slackFailureNotes: slackFailureNotes,
                maximumItems: 40
            )
            var assembled = result.brief
            let consentedWorkspaceIDs = Set(try store.domainSlackWorkspaces().filter(\.localModelConsent).map(\.id))
            let allEvidence = assembled.sections.flatMap { section in
                section.items.compactMap { item -> OllamaEvidenceItem? in
                    if item.source.kind == .slack {
                        guard let workspaceID = item.slackAttribution?.workspaceID,
                              consentedWorkspaceIDs.contains(workspaceID)
                        else { return nil }
                    }
                    return OllamaEvidenceItem(id: item.id, sectionID: section.id, title: item.title, evidenceText: item.summary, sourceName: item.source.name, sourceURL: item.provenance.directURL, publishedAt: item.provenance.publicationDate)
                }
            }
            let evidence = Array(allEvidence.prefix(OllamaProviderLimits.maximumSelectedItems))
            if localGenerationEnabled, ollamaStatus.state == .modelSelected, activeOllamaSelection != nil, !evidence.isEmpty {
                refreshState = .generatingLocally
                let allowedSectionIDs = evidence.reduce(into: [String]()) { identifiers, item in
                    if !identifiers.contains(item.sectionID) { identifiers.append(item.sectionID) }
                }
                let input = OllamaGenerationInput(deterministicBriefID: assembled.id, allowedSectionIDs: allowedSectionIDs, selectedItems: evidence, timeoutSeconds: TimeInterval(p2Settings.generationTimeoutSeconds))
                let providerEpoch = ollamaEpoch
                let outcome = await ollamaProvider.generate(input)
                guard dataEpoch == epoch, !Task.isCancelled else { return }
                if ollamaEpoch == providerEpoch, localGenerationEnabled {
                    switch outcome {
                    case let .generated(generated):
                        assembled = applying(generated, to: assembled)
                        localGenerationMessage = "Generated locally with Ollama · \(generated.provenance.selectedModelName ?? "selected model")"
                        lastLocalGenerationAt = generated.provenance.generatedAt
                        try store.persistGenerationProvenance(generated.provenance)
                    case let .fallback(fallback):
                        assembled = applying(fallback, to: assembled)
                        localGenerationMessage = "Deterministic fallback used: \(fallback.failure.localizedDescription)"
                        try store.persistGenerationProvenance(fallback.provenance)
                    }
                    let status = await ollamaProvider.status()
                    guard dataEpoch == epoch, ollamaEpoch == providerEpoch, !Task.isCancelled else { return }
                    try reconcileProviderStatus(status)
                }
            } else if localGenerationEnabled {
                localGenerationMessage = evidence.isEmpty
                    ? "Deterministic briefing preserved. No evidence is currently eligible for local-model processing."
                    : "Deterministic fallback used. Check Ollama and select an installed model to enable local summaries."
            } else {
                localGenerationMessage = "Deterministic briefing mode. Local generation is disabled."
            }
            guard dataEpoch == epoch, !Task.isCancelled else { return }
            brief = assembled
            briefPresentationContext = .today
            try store.record(assembled)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try store.recordBriefAssembly(.init(id: assembled.id, generatedAt: assembled.generation.generatedAt, selectedEntryCount: assembled.itemCount, excludedEntryCount: result.excludedItemIDs.count, enabledSourceCount: enabledIDs.count + Set(slackEvidence.map(\.workspaceID)).count, failureNotes: try encoder.encode(result.failureNotes)))
            applyReadStates(); try reloadHistory()
        } catch { errorMessage = error.localizedDescription }
    }

    func rebuildBriefAfterSlackChange(failureNotes: [String] = []) async {
        guard allowPersistenceMutationDuringUpdate() else { return }
        dataEpoch &+= 1
        let epoch = dataEpoch
        let priorFeedRefreshState = refreshState
        let feedFailures = subscriptions.compactMap { subscription -> String? in
            guard subscription.enabled, let failure = subscription.failure else { return nil }
            return "\(subscription.title): \(failure.message)"
        }
        await assembleBrief(failureNotes: feedFailures, slackFailureNotes: failureNotes, epoch: epoch)
        if refreshState == .generatingLocally { refreshState = priorFeedRefreshState }
        rebuildCatalogs()
    }

    func cancelSlackLocalGeneration() {
        ollamaEpoch &+= 1
        ollamaTask?.cancel()
        ollamaTask = nil
        activeOllamaSynchronizationTrigger = nil
        Task { await ollamaProvider.cancelGeneration() }
    }

    func openSlackEvidence(_ evidenceID: String) {
        Task { [weak self] in
            guard let self, let url = await slackController.resolvePermalink(evidenceID: evidenceID) else { return }
            NSWorkspace.shared.open(url)
        }
    }

    func checkOllama() {
        startOllamaSynchronization(trigger: .manual)
    }

    /// Waits only for the currently admitted Ollama synchronization snapshot.
    /// It never enables the provider or starts a new request.
    func waitForCurrentOllamaSynchronization() async {
        try? await waitForCurrentOllamaSynchronizationPropagatingCancellation()
    }

    func waitForCurrentOllamaSynchronizationPropagatingCancellation()
        async throws
    {
        let synchronization = ollamaTask
        let synchronizationEpoch = ollamaEpoch
        let cancellationDrain = ollamaCancellationDrainTask
        await withTaskCancellationHandler {
            await synchronization?.value
            if Task.isCancelled,
               ollamaEpoch == synchronizationEpoch {
                _ = invalidateOllamaOperation()
                await ollamaProvider.cancelGeneration()
            }
            await cancellationDrain?.value
        } onCancel: {
            synchronization?.cancel()
        }
        try Task.checkCancellation()
    }

    private func startOllamaSynchronization(
        trigger: OllamaRuntimeSynchronizationTrigger
    ) {
        guard allowPersistenceMutationDuringUpdate() else { return }
        if ollamaTask != nil, activeOllamaSynchronizationTrigger != nil {
            let trace = OllamaTraceContext()
            emitOllamaSynchronization(
                trigger: trigger,
                trace: trace,
                status: .skipped,
                reasonCode: "ollama_runtime_synchronization_coalesced"
            )
            return
        }
        guard ollamaCancellationDrainTask == nil else {
            let trace = OllamaTraceContext()
            emitOllamaSynchronization(
                trigger: trigger,
                trace: trace,
                status: .skipped,
                reasonCode: "ollama_runtime_synchronization_shutdown_in_progress"
            )
            return
        }
        let epoch = beginOllamaOperation()
        activeOllamaSynchronizationTrigger = trigger
        let trace = OllamaTraceContext()
        let startedAt = ProcessInfo.processInfo.systemUptime
        emitOllamaSynchronization(
            trigger: trigger,
            trace: trace,
            status: .started,
            reasonCode: "ollama_runtime_synchronization_started"
        )
        localGenerationMessage = trigger == .startup
            ? "Checking the previously enabled local Ollama service after relaunch…"
            : "Checking the local Ollama service…"
        rebuildCatalogs()
        ollamaTask = Task { [weak self] in
            guard let self else { return }
            await ollamaProvider.setEnabled(true)
            guard isCurrentOllamaOperation(epoch) else { return }
            do {
                let version = try await ollamaProvider.checkVersion(trace: .init(
                    traceID: trace.traceID,
                    parentSpanID: trace.spanID
                ))
                guard isCurrentOllamaOperation(epoch) else { return }
                let catalog = try await ollamaProvider.discoverModels(trace: .init(
                    traceID: trace.traceID,
                    parentSpanID: trace.spanID
                ))
                guard isCurrentOllamaOperation(epoch) else { return }
                localModels = catalog.models; try store.persistModelCatalog(catalog)
                let priorSelectionID = selectedModelID
                var selectionDisappeared = false
                if let priorSelectionID {
                    if catalog.models.contains(where: { $0.id == priorSelectionID }) {
                        activeOllamaSelection = try await ollamaProvider.selectModel(id: priorSelectionID)
                    } else {
                        await ollamaProvider.clearSelection()
                        activeOllamaSelection = nil
                        selectedModelID = nil
                        try store.persistModelSelection(nil, enabled: localGenerationEnabled)
                        selectionDisappeared = true
                    }
                }
                guard isCurrentOllamaOperation(epoch) else { return }
                let providerStatus = await ollamaProvider.status()
                guard isCurrentOllamaOperation(epoch) else { return }
                if selectionDisappeared {
                    ollamaStatus = .init(state: .degraded, checkedAt: providerStatus.checkedAt, lastSuccessfulCheckAt: providerStatus.lastSuccessfulCheckAt, discoveredModelCount: catalog.models.count, selectedModelID: nil, lastFailureCode: .selectedModelDisappeared)
                    localGenerationMessage = "The previously selected Ollama model is no longer installed. Select another discovered model."
                } else {
                    ollamaStatus = providerStatus
                    localGenerationMessage = catalog.models.isEmpty ? "Ollama \(version.version) is running, but no local models are installed." : "Ollama \(version.version) · \(catalog.models.count) installed model\(catalog.models.count == 1 ? "" : "s")."
                }
                try store.upsertProviderSnapshot(.init(stateRaw: ollamaStatus.state.rawValue, checkedAt: ollamaStatus.checkedAt ?? version.checkedAt, lastSuccessfulCheckAt: ollamaStatus.lastSuccessfulCheckAt, serviceVersion: version.version, failureCode: ollamaStatus.lastFailureCode?.rawValue, failureMessage: ollamaStatus.lastFailureCode.flatMap { OllamaFailure($0).errorDescription }))
                emitOllamaSynchronization(
                    trigger: trigger,
                    trace: trace,
                    status: selectionDisappeared || catalog.models.isEmpty ? .degraded : .success,
                    reasonCode: selectionDisappeared
                        ? OllamaFailureCode.selectedModelDisappeared.rawValue
                        : (catalog.models.isEmpty
                            ? OllamaFailureCode.noModels.rawValue
                            : "ollama_runtime_synchronization_succeeded"),
                    startedAt: startedAt
                )
            } catch {
                guard isCurrentOllamaOperation(epoch) else { return }
                let persistedLastSuccess = ollamaStatus.lastSuccessfulCheckAt
                let failedStatus = await ollamaProvider.status()
                guard isCurrentOllamaOperation(epoch) else { return }
                let failure = error as? OllamaFailure
                ollamaStatus = .init(
                    state: failedStatus.state,
                    checkedAt: failedStatus.checkedAt,
                    lastSuccessfulCheckAt: failedStatus.lastSuccessfulCheckAt ?? persistedLastSuccess,
                    discoveredModelCount: failedStatus.discoveredModelCount,
                    selectedModelID: failedStatus.selectedModelID,
                    lastFailureCode: failedStatus.lastFailureCode
                )
                let selectionFailure = failure.map { [.selectedModelDisappeared, .modelNotDiscovered].contains($0.code) } ?? false
                if ollamaStatus.selectedModelID == nil, selectionFailure {
                    activeOllamaSelection = nil
                    selectedModelID = nil
                    try? store.persistModelSelection(nil, enabled: localGenerationEnabled)
                }
                try? store.upsertProviderSnapshot(.init(stateRaw: ollamaStatus.state.rawValue, checkedAt: ollamaStatus.checkedAt ?? Date(), lastSuccessfulCheckAt: ollamaStatus.lastSuccessfulCheckAt, failureCode: failure?.reasonCode, failureMessage: failure?.errorDescription ?? error.localizedDescription))
                localGenerationMessage = failure?.errorDescription ?? error.localizedDescription
                emitOllamaSynchronization(
                    trigger: trigger,
                    trace: trace,
                    status: failure?.code == .requestCancelled ? .skipped : .failed,
                    reasonCode: failure?.reasonCode
                        ?? "ollama_runtime_synchronization_failed",
                    startedAt: startedAt
                )
            }
            synchronizeAgentLokiModelCatalog()
            rebuildCatalogs()
            finishOllamaOperation(epoch)
        }
    }

    func selectOllamaModel(_ id: String?) {
        guard allowPersistenceMutationDuringUpdate() else { return }
        let epoch = beginOllamaOperation()
        guard let id else {
            activeOllamaSelection = nil
            selectedModelID = nil
            do { try store.persistModelSelection(nil, enabled: localGenerationEnabled) } catch { errorMessage = error.localizedDescription }
            ollamaTask = Task { [weak self] in
                guard let self else { return }
                await ollamaProvider.clearSelection()
                guard isCurrentOllamaOperation(epoch) else { return }
                ollamaStatus = await ollamaProvider.status()
                localGenerationMessage = "No Ollama model is selected. Deterministic briefing remains available."
                rebuildCatalogs(); finishOllamaOperation(epoch)
            }
            return
        }
        ollamaTask = Task { [weak self] in
            guard let self else { return }
            do { let selection = try await ollamaProvider.selectModel(id: id); guard isCurrentOllamaOperation(epoch) else { return }; activeOllamaSelection = selection; selectedModelID = id; try store.persistModelSelection(selection, enabled: localGenerationEnabled); ollamaStatus = await ollamaProvider.status(); guard isCurrentOllamaOperation(epoch) else { return }; localGenerationMessage = "Selected \(selection.model.name)." }
            catch { errorMessage = (error as? OllamaFailure)?.errorDescription ?? error.localizedDescription }
            rebuildCatalogs()
            finishOllamaOperation(epoch)
        }
    }

    func setLocalGenerationEnabled(_ enabled: Bool) {
        guard allowPersistenceMutationDuringUpdate() else { return }
        localGenerationEnabled = enabled
        settings.deterministicOnly = !enabled
        if !enabled {
            ollamaEpoch &+= 1
            ollamaTask?.cancel(); ollamaTask = nil
            let provider = ollamaProvider
            Task { await provider.cancelGeneration() }
        }
        do {
            let persistedSelection = try store.modelSelection()
            persistedSelection.modelID = selectedModelID
            persistedSelection.localGenerationEnabled = enabled
            if let activeOllamaSelection { persistedSelection.selectedAt = activeOllamaSelection.selectedAt }
            try store.save()
        }
        catch { errorMessage = error.localizedDescription }
        localGenerationMessage = enabled ? "Local summaries enabled. Check Ollama and select a discovered model." : "Deterministic briefing mode. Local generation is disabled."
    }

    func disableOllama() {
        guard allowPersistenceMutationDuringUpdate() else { return }
        let operationToDrain = invalidateOllamaOperation()
        scheduleOllamaDisableDrain(operation: operationToDrain)
        let previousStatus = ollamaStatus
        localGenerationEnabled = false; settings.deterministicOnly = true; activeOllamaSelection = nil; selectedModelID = nil
        ollamaStatus = .init(state: .disabled, checkedAt: previousStatus.checkedAt, lastSuccessfulCheckAt: previousStatus.lastSuccessfulCheckAt, discoveredModelCount: localModels.count, selectedModelID: nil, lastFailureCode: nil)
        do {
            try store.persistModelSelection(nil, enabled: false)
            try store.upsertProviderSnapshot(.init(stateRaw: OllamaRuntimeState.disabled.rawValue, checkedAt: previousStatus.checkedAt ?? Date(), lastSuccessfulCheckAt: previousStatus.lastSuccessfulCheckAt))
            try store.save()
        } catch { errorMessage = error.localizedDescription }
        synchronizeAgentLokiModelCatalog()
        localGenerationMessage = "Ollama disabled. Deterministic briefing remains available."; rebuildCatalogs()
    }

    func testLocalSummary() {
        guard allowPersistenceMutationDuringUpdate() else { return }
        guard localGenerationEnabled else { errorMessage = "Enable Ollama brief summaries before running the local summary test."; return }
        guard activeOllamaSelection != nil else { errorMessage = "Check Ollama and select an installed model first."; return }
        let epoch = beginOllamaOperation()
        let operationDataEpoch = dataEpoch
        ollamaTask = Task { [weak self] in
            guard let self else { return }
            let input = OllamaGenerationInput(deterministicBriefID: "ollama-local-test", allowedSectionIDs: ["news"], selectedItems: [.init(id: "synthetic-test-item", sectionID: "news", title: "Synthetic local summary test", evidenceText: "This is non-private synthetic evidence used only to test local structured generation.", sourceName: "Loki Brief", sourceURL: nil, publishedAt: nil)], timeoutSeconds: TimeInterval(p2Settings.generationTimeoutSeconds))
            let outcome = await ollamaProvider.generate(input)
            guard isCurrentOllamaOperation(epoch), dataEpoch == operationDataEpoch, localGenerationEnabled else { return }
            switch outcome {
            case let .generated(result): localGenerationMessage = "Local summary test passed · \(result.provenance.selectedModelName ?? "selected model")"; lastLocalGenerationAt = result.provenance.generatedAt; try? store.persistGenerationProvenance(result.provenance)
            case let .fallback(fallback): localGenerationMessage = "Local summary test used deterministic fallback: \(fallback.failure.localizedDescription)"; try? store.persistGenerationProvenance(fallback.provenance)
            }
            ollamaStatus = await ollamaProvider.status(); guard isCurrentOllamaOperation(epoch), dataEpoch == operationDataEpoch else { return }; try? reconcileProviderStatus(ollamaStatus); rebuildCatalogs(); finishOllamaOperation(epoch)
        }
    }

    var currentCivilDay: LocalCalendarDay {
        currentCivilDayProvider()
    }

    var isPresentingHistoricalBrief: Bool {
        briefPresentationContext == .historical
            || brief.resolvedBriefingDay != currentCivilDay
    }

    func navigate(to destination: NavigationDestination) {
        if destination == .today {
            openToday()
        } else {
            selection = destination
        }
    }

    func openToday() {
        presentToday(on: currentCivilDay)
    }

    func synchronizeCurrentDayPresentation() {
        guard briefPresentationContext == .today else { return }
        let day = currentCivilDay
        guard brief.resolvedBriefingDay != day else { return }
        presentToday(on: day)
    }

    func openHistory(id: String) {
        do {
            if let stored = try store.brief(id: id) {
                brief = stored
                applyReadStates()
                briefPresentationContext = .historical
                selection = .today
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func presentToday(on day: LocalCalendarDay) {
        do {
            brief = try latestPersistedBrief(on: day) ?? emptyTodayBrief(on: day)
        } catch {
            brief = emptyTodayBrief(on: day)
            errorMessage = error.localizedDescription
        }
        applyReadStates()
        briefPresentationContext = .today
        selection = .today
    }

    private func latestPersistedBrief(on day: LocalCalendarDay) throws -> Brief? {
        try store.history()
            .lazy
            .filter({ $0.statusRaw != BriefStatus.preview.rawValue })
            .compactMap({ try? $0.decodedBrief() })
            .first(where: { $0.resolvedBriefingDay == day })
    }

    private func emptyTodayBrief(on day: LocalCalendarDay) -> Brief {
        feedEngine.assemble(
            entries: [],
            subscriptions: [],
            preferences: .default,
            briefingDay: day
        ).brief
    }

    func scheduledDeterministicDraft(
        plan: ScheduledBriefingPlan,
        sourceOutcomes: [ScheduledBriefingSourceOutcome],
        vaultOutcome: ScheduledBriefingVaultOutcome?
    ) throws -> ScheduledBriefingDraft {
        let feedIDs = Set(plan.feedSubscriptionIDs)
        let selectedSubscriptions = subscriptions.filter { feedIDs.contains($0.id) }
        let entries = try store.domainFeedEntries(enabledSubscriptionIDs: feedIDs)
        let topics = p2Settings.topicPreferences.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let readStates = try store.readStates()
        let feedFailures = sourceOutcomes.filter { $0.kind == .feed && $0.status.contributesFailure }.flatMap(\.reasonCodes)
        let feedResult = feedEngine.assemble(
            entries: entries,
            subscriptions: selectedSubscriptions,
            preferences: .init(
                topicKeywords: topics,
                sourceWeights: Dictionary(uniqueKeysWithValues: selectedSubscriptions.map { ($0.id, $0.weight) }),
                readStates: readStates,
                briefingWindowHours: 168,
                maximumItems: min(40, plan.budget.maximumNewArchiveItems)
            ),
            failureNotes: feedFailures,
            briefingDay: plan.briefingDay
        )
        let plannedChannelKeys = Set(plan.slackSelections.flatMap { snapshot in
            snapshot.channelIDs.map { "\(snapshot.workspaceID):\($0)" }
        })
        let currentlyEnabledChannelKeys = try plan.slackWorkspaceIDs.reduce(into: Set<String>()) { keys, workspaceID in
            for selection in try store.domainSlackSelections(workspaceID: workspaceID) where selection.enabled {
                keys.insert("\(workspaceID):\(selection.channelID)")
            }
        }
        let selectedChannelKeys = plannedChannelKeys.intersection(currentlyEnabledChannelKeys)
        let slackEvidence = try store.domainSlackEvidence().filter { selectedChannelKeys.contains("\($0.workspaceID):\($0.channelID)") }
        let slackFailures = sourceOutcomes.filter { $0.kind == .slackWorkspace && $0.status.contributesFailure }.flatMap(\.reasonCodes)
        let mixed = mixedEngine.assemble(
            feedResult: feedResult,
            slackEvidence: slackEvidence,
            slackPreferences: .init(readStates: readStates, briefingWindowHours: 168, maximumItems: 40, urgencyTerms: SlackBriefingPreferences.default.urgencyTerms),
            slackFailureNotes: slackFailures,
            maximumItems: 40
        )
        let vaultFailures = vaultOutcome?.status.contributesFailure == true ? (vaultOutcome?.reasonCodes ?? []) : []
        return .init(
            brief: mixed.brief,
            excludedItemCount: mixed.excludedItemIDs.count,
            failureReasonCodes: Array(Set(mixed.failureNotes + vaultFailures)).sorted(),
            localPresentationConsentedWorkspaceIDs: plan.localPresentationConsentedWorkspaceIDs
        )
    }

    func scheduledLocalPresentation(
        draft: ScheduledBriefingDraft,
        timeoutSeconds: TimeInterval? = nil
    ) async -> ScheduledBriefingPresentationOutcome {
        guard localGenerationEnabled,
              ollamaStatus.state == .modelSelected,
              activeOllamaSelection != nil
        else { return .skipped(reasonCode: "scheduled_local_presentation_unavailable") }
        let currentlyConsentedWorkspaceIDs = Set((try? store.domainSlackWorkspaces().filter(\.localModelConsent).map(\.id)) ?? [])
        let consentedWorkspaceIDs = Set(draft.localPresentationConsentedWorkspaceIDs)
            .intersection(currentlyConsentedWorkspaceIDs)
        let evidence = draft.brief.sections.flatMap { section in
            section.items.compactMap { item -> OllamaEvidenceItem? in
                if item.source.kind == .slack {
                    guard let workspaceID = item.slackAttribution?.workspaceID, consentedWorkspaceIDs.contains(workspaceID) else { return nil }
                }
                return .init(id: item.id, sectionID: section.id, title: item.title, evidenceText: item.summary, sourceName: item.source.name, sourceURL: item.provenance.directURL, publishedAt: item.provenance.publicationDate)
            }
        }
        guard !evidence.isEmpty else { return .skipped(reasonCode: "scheduled_local_presentation_no_consented_evidence") }
        let selected = Array(evidence.prefix(OllamaProviderLimits.maximumSelectedItems))
        let sectionIDs = selected.reduce(into: [String]()) { values, item in if !values.contains(item.sectionID) { values.append(item.sectionID) } }
        let outcome = await ollamaProvider.generate(.init(
            deterministicBriefID: draft.brief.id,
            allowedSectionIDs: sectionIDs,
            selectedItems: selected,
            timeoutSeconds: timeoutSeconds
                ?? min(TimeInterval(p2Settings.generationTimeoutSeconds), ScheduledBriefingBudget().maximumOllamaDurationSeconds)
        ))
        switch outcome {
        case let .generated(result):
            return .generated(brief: applying(result, to: draft.brief), provenance: result.provenance)
        case let .fallback(fallback):
            return .fallback(reasonCode: fallback.failure.reasonCode, provenance: fallback.provenance)
        }
    }

    func applyScheduledBriefingResult(_ result: ScheduledBriefingRunResult) {
        do {
            try reloadSubscriptions()
            synchronizeCurrentDayPresentation()
            if let completedBrief = result.brief,
               briefPresentationContext == .today,
               completedBrief.resolvedBriefingDay == currentCivilDay {
                brief = completedBrief
                briefPresentationContext = .today
                applyReadStates()
            }
            try reloadHistory()
            rebuildCatalogs()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshPreview() { guard allowPersistenceMutationDuringUpdate() else { return }; revision += 1; brief = engine.generatePreview(revision: revision); briefPresentationContext = .today; do { try store.record(brief); try reloadHistory() } catch { errorMessage = error.localizedDescription } }
    func toggleRead(_ item: BriefItem) { guard allowPersistenceMutationDuringUpdate() else { return }; do { try store.setRead(item.id, isRead: !item.isRead); applyReadStates() } catch { errorMessage = error.localizedDescription } }
    func saveSettings() { guard allowPersistenceMutationDuringUpdate() else { return }; do { try store.save() } catch { errorMessage = error.localizedDescription } }
    func updateDensity(_ density: BriefingDensity) { guard allowPersistenceMutationDuringUpdate() else { return }; settings.density = density; self.density = density; saveSettings() }
    func saveP2Settings() { guard allowPersistenceMutationDuringUpdate() else { return }; p2Settings.feedRetentionDays = min(max(p2Settings.feedRetentionDays, 1), 365); p2Settings.retainedEntriesPerFeed = min(max(p2Settings.retainedEntriesPerFeed, 1), FeedLimits.maximumRetainedEntriesPerFeed); p2Settings.generationTimeoutSeconds = min(max(p2Settings.generationTimeoutSeconds, 5), 120); saveSettings() }
    func setDeterministicOnly(_ enabled: Bool) {
        guard allowPersistenceMutationDuringUpdate() else { return }
        settings.deterministicOnly = enabled
        saveSettings()
        if enabled { setLocalGenerationEnabled(false) }
    }
    func setTopicPreferences(_ value: String) {
        guard allowPersistenceMutationDuringUpdate() else { return }
        p2Settings.topicPreferences = value
        saveP2Settings()
    }
    func setFeedRetentionDays(_ value: Int) {
        guard allowPersistenceMutationDuringUpdate() else { return }
        p2Settings.feedRetentionDays = value
        saveP2Settings()
    }
    func setRetainedEntriesPerFeed(_ value: Int) {
        guard allowPersistenceMutationDuringUpdate() else { return }
        p2Settings.retainedEntriesPerFeed = value
        saveP2Settings()
    }
    func setGenerationTimeoutSeconds(_ value: Int) {
        guard allowPersistenceMutationDuringUpdate() else { return }
        p2Settings.generationTimeoutSeconds = value
        saveP2Settings()
    }
    func setPreviewFixturesEnabled(_ enabled: Bool) {
        guard allowPersistenceMutationDuringUpdate() else { return }
        p2Settings.previewFixturesEnabled = enabled
        saveP2Settings()
        if !enabled, brief.status == .preview {
            brief = emptyTodayBrief(on: currentCivilDay)
            briefPresentationContext = .today
        }
        rebuildCatalogs()
    }
    func previewReset() { guard allowPersistenceMutationDuringUpdate() else { return }; revision = 1; brief = engine.generatePreview(revision: revision); briefPresentationContext = .today; do { try store.seedFoundationSnapshots(); try store.record(brief); applyReadStates(); try reloadHistory() } catch { errorMessage = error.localizedDescription } }

    func deleteAllData() async {
        // An empty persisted workspace list does not prove that an OAuth callback
        // is not in flight. Every whole-app reset therefore enters the Slack
        // deletion barrier before clearing local persistence.
        await deleteAllDataIncludingSlackCredentials()
    }

    func shutdownForApplicationTermination() async {
        await cancelAndDrainOllamaOperation()
        _ = await connectorSourcesController.prepareForUpdateInstallation()
        await chatController?.shutdownForApplicationTermination()
        await p5Controller?.shutdown()
    }

    func deleteAllDataIncludingSlackCredentials() async {
        guard !updateInstallationInProgress, !deleteAllInProgress else {
            errorMessage = "Delete All is unavailable while update installation is prepared. Cancel or finish the update first."
            return
        }
        deleteAllInProgress = true
        defer { deleteAllInProgress = false }
        // Startup reconciliation is internal Vault work. Drain it before the
        // explicit foreground-operation safety check so an immediate Delete All
        // cannot fail nondeterministically while the launch refresh is finishing.
        let startupTask = vaultBootstrapTask
        await startupTask?.value
        vaultBootstrapTask = nil
        await chatController?.prepareForDeleteAll()
        if let p5Controller {
            guard await p5Controller.prepareForDeleteAll() else {
                await chatController?.resumeAfterDeleteAllAbort()
                return
            }
        }
        guard await connectorSourcesController.prepareForWholeAppDataDeletion() else {
            errorMessage = connectorSourcesController.errorMessage
                ?? "Connector credential cleanup did not complete; local data was preserved."
            await p5Controller?.resumeAfterDeleteAllAbort()
            await chatController?.resumeAfterDeleteAllAbort()
            return
        }
        guard await slackController.prepareForWholeAppDataDeletion() else {
            errorMessage = slackController.errorMessage
            connectorSourcesController.resumeAfterWholeAppDataDeletionAbort()
            await slackController.resumeAfterWholeAppDataDeletionAbort()
            await p5Controller?.resumeAfterDeleteAllAbort()
            await chatController?.resumeAfterDeleteAllAbort()
            return
        }
        let vaultDeleted = await vaultController.deleteAllVaultData()
        let vaultFailure = vaultController.errorMessage
        guard vaultDeleted else {
            errorMessage = vaultFailure ?? "Vault cleanup did not complete; local data was preserved so deletion can be retried safely."
            connectorSourcesController.resumeAfterWholeAppDataDeletionAbort()
            await slackController.resumeAfterWholeAppDataDeletionAbort()
            await p5Controller?.resumeAfterDeleteAllAbort()
            await chatController?.resumeAfterDeleteAllAbort()
            return
        }
        guard await chatController?.deleteP8DerivedAndCredentialData() ?? true else {
            errorMessage = "P8 semantic-index or Web Research credential cleanup did not complete; local data was preserved so deletion can be retried safely."
            connectorSourcesController.resumeAfterWholeAppDataDeletionAbort()
            await slackController.resumeAfterWholeAppDataDeletionAbort()
            await p5Controller?.resumeAfterDeleteAllAbort()
            await chatController?.resumeAfterDeleteAllAbort()
            return
        }
        await cancelAndDrainOllamaOperation()
        guard performLocalDataDeletion() else {
            connectorSourcesController.resumeAfterWholeAppDataDeletionAbort()
            await slackController.resumeAfterWholeAppDataDeletionAbort()
            await p5Controller?.resumeAfterDeleteAllAbort()
            await chatController?.resumeAfterDeleteAllAbort()
            return
        }
        slackController.reloadAfterWholeAppDataDeletion()
        connectorSourcesController.reloadAfterWholeAppDataDeletion()
        p5Controller?.completeDeleteAll()
        await chatController?.completeDeleteAll()
    }

    func assessApplicationUpdateReadiness() -> ApplicationUpdateParticipantAssessment {
        applicationUpdateBlockingReason.map(ApplicationUpdateParticipantAssessment.blocked) ?? .ready
    }

    func prepareForApplicationUpdate() async -> ApplicationUpdateParticipantPreparation {
        if let reason = applicationUpdateBlockingReason { return .blocked(reason) }
        updateInstallationInProgress = true

        guard await p5Controller?.prepareForUpdateInstallation() ?? true else {
            updateInstallationInProgress = false
            return .blocked(.activeDeliveryRun)
        }
        guard await connectorSourcesController.prepareForUpdateInstallation() else {
            await p5Controller?.resumeAfterUpdateInstallationAbort()
            updateInstallationInProgress = false
            return .blocked(.activeConnectorWork)
        }
        guard slackController.prepareForUpdateInstallation() else {
            await p5Controller?.resumeAfterUpdateInstallationAbort()
            updateInstallationInProgress = false
            return .blocked(.activeSlackWork)
        }
        guard await chatController?.prepareForApplicationUpdate() ?? true else {
            slackController.resumeAfterUpdateInstallationAbort()
            await p5Controller?.resumeAfterUpdateInstallationAbort()
            updateInstallationInProgress = false
            return .degraded(.preparationFailed)
        }
        do {
            try store.save()
        } catch {
            let chatRecovered = await chatController?.recoverAfterApplicationUpdateAbort() ?? true
            slackController.resumeAfterUpdateInstallationAbort()
            await p5Controller?.resumeAfterUpdateInstallationAbort()
            updateInstallationInProgress = !chatRecovered
            return .degraded(.preparationFailed)
        }
        if let vaultFailure = await vaultController.prepareForUpdateInstall() {
            let chatRecovered = await chatController?.recoverAfterApplicationUpdateAbort() ?? true
            slackController.resumeAfterUpdateInstallationAbort()
            await p5Controller?.resumeAfterUpdateInstallationAbort()
            updateInstallationInProgress = !chatRecovered
            return vaultFailure == "vault_work_active"
                ? .blocked(.activeVaultDatabaseWork)
                : .degraded(.preparationFailed)
        }
        return .prepared(fulfilling: [.saveState, .quiesceAndCloseStoresForTermination])
    }

    func recoverAfterApplicationUpdateAbort() async -> ApplicationUpdateParticipantRecovery {
        let vaultRecovered = await vaultController.resumeAfterUpdateInstallAbort()
        // Vault-backed read-only tools must remain unavailable when the archive
        // did not recover. Chat recovery therefore follows successful Vault
        // recovery instead of reopening its own admission independently.
        let chatRecovered = vaultRecovered
            ? await chatController?.recoverAfterApplicationUpdateAbort() ?? true
            : false
        slackController.resumeAfterUpdateInstallationAbort()
        await p5Controller?.resumeAfterUpdateInstallationAbort()
        updateInstallationInProgress = !(vaultRecovered && chatRecovered)
        return vaultRecovered && chatRecovered ? .recovered : .failed
    }

    private func allowPersistenceMutationDuringUpdate() -> Bool {
        guard !updateInstallationInProgress, !deleteAllInProgress else {
            if deleteAllInProgress {
                errorMessage = "Wait for Delete All Local Data to finish before starting new work or changing local data."
                return false
            }
            errorMessage = "Finish active work and retry the pending update installation, or quit Loki Brief before changing local data."
            return false
        }
        return true
    }

    private var applicationUpdateBlockingReason: ApplicationUpdateReadinessReason? {
        if updateInstallationInProgress { return .updateAlreadyInProgress }
        if deleteAllInProgress
            || p5Controller?.deletionInProgress == true
            || slackController.wholeAppDeletionInProgress
            || vaultController.deletionInProgress {
            return .deleteAllInProgress
        }
        if refreshTask != nil || activeAddFeedOperationID != nil || activeFeedCancellationCleanupID != nil {
            return .activeFeedWork
        }
        if ollamaTask != nil || ollamaCancellationDrainTask != nil {
            return .activeLocalGenerationWork
        }
        if chatController?.isGenerating == true { return .activeChatGeneration }
        if (chatController?.activeToolCount ?? 0) > 0 { return .activeChatToolWork }
        if chatController?.assessingModelIDs.isEmpty == false { return .activeChatModelAssessment }
        if chatController?.hasUpdateBlockingWork == true { return .activeChatP8Work }
        if p5Controller?.hasUpdateBlockingWork == true { return .activeDeliveryRun }
        if connectorSourcesController.hasUpdateBlockingWork {
            return .activeConnectorWork
        }
        if slackController.hasUpdateBlockingWork { return .activeSlackWork }
        if vaultController.hasUpdateBlockingWork { return .activeVaultDatabaseWork }
        return nil
    }

    @discardableResult
    private func performLocalDataDeletion() -> Bool {
        dataEpoch &+= 1
        ollamaEpoch &+= 1
        refreshTask?.cancel(); refreshTask = nil
        activeRefreshSubscriptionIDs.removeAll()
        activeRefreshOperationID = nil
        activeAddFeedOperationID = nil
        ollamaTask?.cancel(); ollamaTask = nil
        activeOllamaSynchronizationTrigger = nil
        beginFeedCancellationCleanup(disableProvider: true)
        do {
            try store.deleteAllLocalData()
            settings = try store.settings(); p2Settings = try store.p2Settings(); density = settings.density
            history = []; historyCount = 0; subscriptions = []; localModels = []; selectedModelID = nil
            activeOllamaSelection = nil; localGenerationEnabled = false; lastLocalGenerationAt = nil
            ollamaStatus = .init(state: .disabled, checkedAt: nil, discoveredModelCount: 0, selectedModelID: nil, lastFailureCode: nil)
            sourceRefreshStates = [:]; refreshState = .idle; refreshMessage = "Feeds refresh manually or through an enabled Delivery schedule while Loki Brief is running."
            brief = emptyTodayBrief(on: currentCivilDay)
            briefPresentationContext = .today
            errorMessage = nil
            rebuildCatalogs()
            try p5Controller?.reloadAfterDeleteAll()
            synchronizeAgentLokiModelCatalog()
            return true
        }
        catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func synchronizeAgentLokiModelCatalog() {
        chatController?.synchronizeOllamaCatalog(
            models: localModels,
            status: ollamaStatus,
            providerVersion: try? store.providerSnapshot()?.serviceVersion
        )
    }

    private func applying(_ generated: OllamaGenerationResult, to deterministic: Brief) -> Brief {
        let summaries = Dictionary(uniqueKeysWithValues: generated.summary.sectionSummaries.map { ($0.sectionID, $0.summary) })
        let provenance = generated.provenance
        let locallyProcessedIDs = Set(provenance.sourceItemIdentifiers)
        let sections = deterministic.sections.map { section in
            BriefSection(
                id: section.id,
                title: section.title,
                items: section.items.map { item in
                    guard let attribution = item.slackAttribution,
                          locallyProcessedIDs.contains(item.id)
                    else { return item }
                    return BriefItem(
                        id: item.id,
                        title: item.title,
                        summary: item.summary,
                        priority: item.priority,
                        source: item.source,
                        provenance: item.provenance,
                        isRead: item.isRead,
                        availabilityMessage: item.availabilityMessage,
                        rankingExplanation: item.rankingExplanation,
                        corroboratingSourceIDs: item.corroboratingSourceIDs ?? [],
                        slackAttribution: .init(
                            workspaceID: attribution.workspaceID,
                            workspaceName: attribution.workspaceName,
                            channelID: attribution.channelID,
                            channelName: attribution.channelName,
                            authorName: attribution.authorName,
                            messageTimestamp: attribution.messageTimestamp,
                            priorityReasonCode: attribution.priorityReasonCode,
                            locallyGenerated: true
                        )
                    )
                },
                summary: summaries[section.id] ?? section.summary
            )
        }
        return Brief(id: deterministic.id, date: deterministic.date, title: deterministic.title, summary: generated.summary.overallSummary, status: deterministic.status, sections: sections, generation: .init(engineID: deterministic.generation.engineID, generatedAt: provenance.generatedAt, status: deterministic.status, reasonCode: "ollama_local_summary_validated", fixtureRevision: deterministic.generation.fixtureRevision, providerKind: provenance.providerKind, modelName: provenance.selectedModelName, promptTemplateVersion: provenance.promptTemplateVersion, outputSchemaVersion: provenance.schemaVersion, sourceItemIDs: provenance.sourceItemIdentifiers, fallbackStatus: provenance.fallbackStatus.rawValue, durationMilliseconds: provenance.durationMilliseconds, promptTokenCount: provenance.promptTokenCount, completionTokenCount: provenance.outputTokenCount, validationResult: provenance.validationResult.rawValue), partialFailureMessage: deterministic.partialFailureMessage, briefingDay: deterministic.resolvedBriefingDay)
    }

    private func applying(_ fallback: OllamaGenerationFallback, to deterministic: Brief) -> Brief {
        let provenance = fallback.provenance
        let fallbackMessage = "Local generation fell back to deterministic: \(fallback.failure.localizedDescription)"
        let combinedFailure = [deterministic.partialFailureMessage, fallbackMessage].compactMap { $0 }.joined(separator: " ")
        return Brief(id: deterministic.id, date: deterministic.date, title: deterministic.title, summary: deterministic.summary, status: deterministic.status, sections: deterministic.sections, generation: .init(engineID: deterministic.generation.engineID, generatedAt: deterministic.generation.generatedAt, status: deterministic.status, reasonCode: "deterministic_fallback_preserved", fixtureRevision: deterministic.generation.fixtureRevision, providerKind: "deterministic", modelName: provenance.selectedModelName, promptTemplateVersion: provenance.promptTemplateVersion, outputSchemaVersion: provenance.schemaVersion, sourceItemIDs: provenance.sourceItemIdentifiers, fallbackStatus: provenance.failureReasonCode, durationMilliseconds: provenance.durationMilliseconds, promptTokenCount: provenance.promptTokenCount, completionTokenCount: provenance.outputTokenCount, validationResult: provenance.validationResult.rawValue), partialFailureMessage: combinedFailure, briefingDay: deterministic.resolvedBriefingDay)
    }

    private func applyReadStates() {
        guard let states = try? store.readStates() else { return }
        brief = Brief(id: brief.id, date: brief.date, title: brief.title, summary: brief.summary, status: brief.status, sections: brief.sections.map { section in BriefSection(id: section.id, title: section.title, items: section.items.map { item in var changed = item; changed.isRead = states[item.id] ?? false; return changed }, summary: section.summary) }, generation: brief.generation, partialFailureMessage: brief.partialFailureMessage, briefingDay: brief.resolvedBriefingDay)
    }

    private func reloadHistory() throws { history = try store.history().map(\.historyEntry); historyCount = history.count }
    private func reloadSubscriptions() throws { subscriptions = try store.domainFeedSubscriptions() }

    private static func shouldSynchronizeOllamaOnLaunch(
        from snapshot: StoredModelProviderSnapshotP2?
    ) -> Bool {
        guard let stateRaw = snapshot?.stateRaw,
              let state = OllamaRuntimeState(rawValue: stateRaw)
        else { return false }
        return state != .disabled
    }

    private func beginOllamaOperation() -> UInt64 {
        ollamaEpoch &+= 1
        ollamaTask?.cancel()
        ollamaTask = nil
        activeOllamaSynchronizationTrigger = nil
        return ollamaEpoch
    }

    private func isCurrentOllamaOperation(_ epoch: UInt64) -> Bool {
        ollamaEpoch == epoch && !Task.isCancelled
    }

    private func finishOllamaOperation(_ epoch: UInt64) {
        if ollamaEpoch == epoch {
            ollamaTask = nil
            activeOllamaSynchronizationTrigger = nil
        }
    }

    private func invalidateOllamaOperation() -> Task<Void, Never>? {
        ollamaEpoch &+= 1
        let operation = ollamaTask
        operation?.cancel()
        ollamaTask = nil
        activeOllamaSynchronizationTrigger = nil
        return operation
    }

    private func scheduleOllamaDisableDrain(
        operation: Task<Void, Never>?
    ) {
        let provider = ollamaProvider
        let priorDrain = ollamaCancellationDrainTask
        let drainID = UUID()
        ollamaCancellationDrainID = drainID
        ollamaCancellationDrainTask = Task { [weak self] in
            await provider.setEnabled(false)
            await operation?.value
            await priorDrain?.value
            guard let self, self.ollamaCancellationDrainID == drainID else { return }
            self.ollamaCancellationDrainTask = nil
            self.ollamaCancellationDrainID = nil
        }
    }

    private func cancelAndDrainOllamaOperation() async {
        let operation = invalidateOllamaOperation()
        let pendingDrain = ollamaCancellationDrainTask
        ollamaCancellationDrainTask = nil
        ollamaCancellationDrainID = nil
        await ollamaProvider.setEnabled(false)
        await operation?.value
        await pendingDrain?.value
    }

    private func emitOllamaSynchronization(
        trigger: OllamaRuntimeSynchronizationTrigger,
        trace: OllamaTraceContext,
        status: OllamaTraceStatus,
        reasonCode: String,
        startedAt: TimeInterval? = nil
    ) {
        let durationMilliseconds = startedAt.map {
            let elapsed = max(0, ProcessInfo.processInfo.systemUptime - $0)
            return min(
                Int(elapsed * 1_000),
                Int(OllamaProviderLimits.maximumTimeoutSeconds * 2_000)
            )
        }
        ollamaSynchronizationEventSink(.init(
            traceID: trace.traceID,
            spanID: trace.spanID,
            parentSpanID: trace.parentSpanID,
            status: status,
            reasonCode: reasonCode,
            durationMilliseconds: durationMilliseconds,
            trigger: trigger
        ))
    }

    private func reconcileProviderStatus(_ status: OllamaProviderStatusSnapshot) throws {
        ollamaStatus = status
        if status.selectedModelID == nil, activeOllamaSelection != nil {
            activeOllamaSelection = nil
            selectedModelID = nil
            try store.persistModelSelection(nil, enabled: localGenerationEnabled)
        }
        try store.upsertProviderSnapshot(.init(
            stateRaw: status.state.rawValue,
            checkedAt: status.checkedAt ?? Date(),
            lastSuccessfulCheckAt: status.lastSuccessfulCheckAt,
            failureCode: status.lastFailureCode?.rawValue,
            failureMessage: status.lastFailureCode.flatMap { OllamaFailure($0).errorDescription }
        ))
    }

    private func rebuildCatalogs() {
        let feedState: SourceConnectionState = subscriptions.contains(where: { $0.state == .connected }) ? .connected : .available
        sources = FoundationCatalog.sources.map { source in
            if source.kind == .newsFeeds { return .init(id: source.id, name: source.name, kind: source.kind, state: feedState, capabilities: source.capabilities, detail: "User-managed RSS, Atom, and JSON Feed subscriptions. Manual refresh or bounded refresh from an enabled while-running Delivery schedule.") }
            if source.kind == .slack {
                let state: SourceConnectionState
                let detail: String
                switch slackController.availability {
                case .configurationRequired:
                    state = .authorizationRequired
                    detail = "Public-client Slack configuration is required. No browser or Slack request starts until Connect Slack is available and selected."
                case .disconnected:
                    state = .disconnected
                    detail = "Read-only Slack source authorization is disconnected. Channel selection and refresh are always explicit."
                case .connected:
                    state = .connected
                    detail = "Read-only selected-channel Slack evidence refreshes manually or through an enabled Delivery schedule while Loki Brief is running."
                }
                return .init(id: source.id, name: source.name, kind: source.kind, state: state, capabilities: source.capabilities, detail: detail)
            }
            if source.kind == .previewFixtures, !p2Settings.previewFixturesEnabled { return .init(id: source.id, name: source.name, kind: source.kind, state: .disconnected, capabilities: source.capabilities, detail: "Synthetic Preview Fixtures are disabled in this release.") }
            return source
        }
        let providerState = ModelProviderState(rawValue: ollamaStatus.state.rawValue) ?? .degraded
        providers = FoundationCatalog.providers.map { provider in
            guard provider.kind == .ollama else { return provider }
            return .init(id: provider.id, name: provider.name, kind: provider.kind, state: providerState, capabilities: provider.capabilities, detail: localGenerationMessage)
        }
    }
}

private actor DisabledFeedClient: FeedRetrieving {
    func fetch(_ subscription: FeedSubscription, trace: FeedTraceContext) async throws -> FeedFetchResult { throw FeedFetchFailure(.networkUnavailable, message: "Live network loading is disabled in the hosted test application.") }
    func cancelAll() async { }
}
