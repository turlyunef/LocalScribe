import XCTest
import LocalScribeCore
@testable import LocalScribe

@MainActor
final class AutomaticSummariesTests: XCTestCase {
    func testDefaultIsEnabledAndPreferenceSurvivesRelaunchIndependentlyOfBackgroundRecognition() async throws {
        let suite = "LocalScribeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root)
        let model = AppModel(repository: repo, startServices: false, userDefaults: defaults)
        XCTAssertTrue(model.automaticSummaries)
        for background in [false, true] {
            model.backgroundRecognition = background
            for enabled in [false, true] {
                model.automaticSummaries = enabled
                XCTAssertEqual(defaults.object(forKey: "automaticSummaries") as? Bool, enabled)
                let relaunched = AppModel(repository: repo, startServices: false, userDefaults: defaults)
                XCTAssertEqual(relaunched.automaticSummaries, enabled)
                XCTAssertEqual(relaunched.backgroundRecognition, background)
                await relaunched.shutdown()
            }
        }
        await model.shutdown()
    }
}
