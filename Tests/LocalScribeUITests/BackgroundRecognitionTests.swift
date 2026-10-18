import XCTest
import LocalScribeCore
@testable import LocalScribe

@MainActor
final class BackgroundRecognitionTests: XCTestCase {
    func testDefaultIsEnabledAndSavedChoiceSurvivesRelaunch() throws {
        let suite = "LocalScribeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root)
        let model = AppModel(repository: repo, startServices: false, userDefaults: defaults)
        XCTAssertTrue(model.backgroundRecognition)

        for enabled in [false, true] {
            model.backgroundRecognition = enabled
            XCTAssertEqual(defaults.object(forKey: "backgroundRecognition") as? Bool, enabled)
            let relaunched = AppModel(repository: repo, startServices: false, userDefaults: defaults)
            XCTAssertEqual(relaunched.backgroundRecognition, enabled)
        }
    }

    func testExistingDisabledPreferenceIsRespected() throws {
        let suite = "LocalScribeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "backgroundRecognition")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(repository: try RecordingRepository(root: root), startServices: false,
                             userDefaults: defaults)
        XCTAssertFalse(model.backgroundRecognition)
    }
}
