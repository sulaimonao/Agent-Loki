import Foundation

protocol SchedulerClock: Sendable {
    func now() async -> Date
    func sleep(until deadline: Date, tolerance: Duration?) async throws
}

struct LiveSchedulerClock: SchedulerClock {
    func now() async -> Date { Date() }

    func sleep(until deadline: Date, tolerance: Duration? = .seconds(1)) async throws {
        let interval = max(0, deadline.timeIntervalSince(Date()))
        try await ContinuousClock().sleep(for: .seconds(interval), tolerance: tolerance)
    }
}
