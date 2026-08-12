import Foundation
import XCTest
@testable import LokiBrief

@MainActor
final class LokiBriefReleaseSmokeTests: XCTestCase {
    func testFirstLaunchOnboardingAndSourceListUseDisposableState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "loki-v1-rc-first-launch-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }

        var model: AppModel? = try AppModel.makeLive(
            isTesting: true,
            isolatedTestDataRoot: root,
            arguments: ["LokiBrief"],
            environment: [:]
        )
        let firstLaunch = try XCTUnwrap(model)

        XCTAssertFalse(firstLaunch.store.isInMemory)
        XCTAssertTrue(firstLaunch.store.usesExplicitStorageURL)
        XCTAssertFalse(firstLaunch.vaultController.databaseIsInMemory)
        XCTAssertEqual(firstLaunch.selection, .today)
        XCTAssertTrue(NavigationDestination.allCases.contains(.sources))
        XCTAssertTrue(NavigationDestination.allCases.contains(.privacy))
        XCTAssertEqual(firstLaunch.slackController.workspaces, [])
        XCTAssertEqual(firstLaunch.connectorSourcesController.statuses, [])

        firstLaunch.navigate(to: .sources)
        XCTAssertEqual(firstLaunch.selection, .sources)
        firstLaunch.navigate(to: .privacy)
        XCTAssertEqual(firstLaunch.selection, .privacy)

        await firstLaunch.shutdownForApplicationTermination()
        model = nil
    }
}
