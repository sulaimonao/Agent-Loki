import Foundation

final class LokiApplicationUpdateParticipant: ApplicationUpdateReadinessParticipant, @unchecked Sendable {
    nonisolated let identifier = "loki_application_runtime"
    nonisolated let preparationOrder = 100
    nonisolated let requiredPreparationContracts: Set<ApplicationUpdatePreparationContract> = [
        .saveState,
        .quiesceAndCloseStoresForTermination,
    ]

    @MainActor private weak var model: AppModel?

    @MainActor
    init(model: AppModel) {
        self.model = model
    }

    func assessApplicationUpdateReadiness() async -> ApplicationUpdateParticipantAssessment {
        await assessOnMainActor()
    }

    func prepareForApplicationUpdate() async -> ApplicationUpdateParticipantPreparation {
        await prepareOnMainActor()
    }

    func recoverAfterApplicationUpdateAbort() async -> ApplicationUpdateParticipantRecovery {
        await recoverOnMainActor()
    }

    @MainActor
    private func assessOnMainActor() -> ApplicationUpdateParticipantAssessment {
        model?.assessApplicationUpdateReadiness() ?? .degraded(.preparationFailed)
    }

    @MainActor
    private func prepareOnMainActor() async -> ApplicationUpdateParticipantPreparation {
        guard let model else { return .degraded(.preparationFailed) }
        return await model.prepareForApplicationUpdate()
    }

    @MainActor
    private func recoverOnMainActor() async -> ApplicationUpdateParticipantRecovery {
        guard let model else { return .failed }
        return await model.recoverAfterApplicationUpdateAbort()
    }
}
