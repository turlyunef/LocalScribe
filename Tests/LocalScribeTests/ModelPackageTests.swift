import Foundation
import XCTest
@testable import LocalScribeCore

/// Collects the `reportInvalid` callbacks of an installation scan the same way
/// the app aggregates them before reporting one message.
private final class InvalidProfileLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(profile: ModelProfile, reason: String)] = []
    func append(_ profile: ModelProfile, _ error: Error) {
        lock.lock(); defer { lock.unlock() }
        entries.append((profile, error.localizedDescription))
    }
    var values: [(profile: ModelProfile, reason: String)] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }
}

/// Task support of profiles, package matching by pinned files, the single
/// verified installation shared by compatible assignments, readiness with
/// removal and file-hold leases, and the byte-limit sources.
final class ModelPackageTests: XCTestCase {
    private let hardware = ModelHardware(chip: "Fixture M1", memoryBytes: 16 * 1_073_741_824, cpuCores: 8,
                                         gpuWorkingSetBytes: 12 * 1_073_741_824, appleSilicon: true, supportsMetal: true)

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Disk.directory(root)
        addTeardownBlock { [root] in try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// A profile whose pinned files exist on disk under the models root.
    @discardableResult
    private func makeProfile(id: String, role: ModelRole?, modelsRoot: URL, contents: [String] = ["weights"],
                             tasks: Set<ModelTask>? = nil, packageID: String? = nil,
                             limitBytes: Int64? = nil, onDisk: Bool = true,
                             memoryGB: Int? = nil) throws -> ModelProfile {
        var files: [ModelFile] = []
        for (index, text) in contents.enumerated() {
            let name = "file-\(index).bin"
            let url = modelsRoot.appendingPathComponent(id).appendingPathComponent(name)
            let sha: String
            if onDisk {
                try Disk.directory(url.deletingLastPathComponent())
                try Data(text.utf8).write(to: url)
                sha = try Disk.hash(url)
            } else {
                sha = ByteContentIdentity.sha256Hex(Data(text.utf8))
            }
            files.append(ModelFile(path: name, localPath: name, size: Int64(text.utf8.count), sha256: sha))
        }
        return ModelProfile(id: id, repository: "test/\(id)", revision: "rev-1", license: "test", files: files,
                            role: role, recommendedMemoryGB: memoryGB, workingMemoryGB: memoryGB,
                            supportedTasks: tasks, packageID: packageID, anonymizationInputLimitBytes: limitBytes)
    }

    // MARK: - Task support and package identity

    func testDerivedTaskSupportFollowsRoleUntilCatalogQualifiesTheProfile() throws {
        let modelsRoot = try makeRoot().appendingPathComponent("models")
        let summary = try makeProfile(id: "summary-9b", role: .summary, modelsRoot: modelsRoot)
        XCTAssertEqual(summary.effectiveSupportedTasks, [.summary])
        XCTAssertFalse(summary.supports(.anonymization))
        let diagram = try makeProfile(id: "diagram-vlm", role: .diagram, modelsRoot: modelsRoot)
        XCTAssertEqual(diagram.effectiveSupportedTasks, [.diagramRecognition])
        let asr = try makeProfile(id: "asr", role: .asr, modelsRoot: modelsRoot)
        XCTAssertTrue(asr.effectiveSupportedTasks.isEmpty)

        // An explicit catalog value (filled by qualification, work 13) wins.
        let qualified = try makeProfile(id: "summary-9b", role: .summary, modelsRoot: modelsRoot,
                                        tasks: [.summary, .diagramRecognition, .anonymization])
        XCTAssertEqual(qualified.effectiveSupportedTasks, Set(ModelTask.allCases))
    }

    func testProfilesWithEqualPinnedFilesShareOnePackageAndExplicitReferenceWins() throws {
        let modelsRoot = try makeRoot().appendingPathComponent("models")
        let one = try makeProfile(id: "shared-9b", role: .summary, modelsRoot: modelsRoot, contents: ["a", "b"])
        let two = try makeProfile(id: "shared-9b-vlm", role: .diagram, modelsRoot: modelsRoot, contents: ["a", "b"])
        let other = try makeProfile(id: "other", role: .summary, modelsRoot: modelsRoot, contents: ["a", "c"])
        XCTAssertEqual(one.effectivePackageID, two.effectivePackageID)
        XCTAssertNotEqual(one.effectivePackageID, other.effectivePackageID)

        // Equal triples in a different array order still match: the identity
        // hashes the canonicalized path:size:sha set, not the catalog order.
        let reversed = Array(one.files.reversed())
        XCTAssertEqual(ModelPackage.identity(ofFiles: reversed), one.effectivePackageID)

        // An explicit package reference overrides the derived identity.
        let explicit = try makeProfile(id: "explicit", role: .summary, modelsRoot: modelsRoot,
                                       contents: ["a", "b"], packageID: "pkg-custom")
        XCTAssertEqual(explicit.effectivePackageID, "pkg-custom")

        let index = ModelPackageIndex(catalog: ModelCatalog(models: [one, two, other, explicit]))
        XCTAssertEqual(index.memberProfileIDs(of: one.effectivePackageID), ["shared-9b", "shared-9b-vlm"])
        XCTAssertEqual(index.package(withID: one.effectivePackageID)?.totalBytes, 2)
        XCTAssertEqual(index.memberProfileIDs(of: "pkg-custom"), ["explicit"])
    }

    func testTaskSupportAndHardwareReasonsCompose() throws {
        let modelsRoot = try makeRoot().appendingPathComponent("models")
        let plainSummary = try makeProfile(id: "summary-9b", role: .summary, modelsRoot: modelsRoot)
        let anonymization = ModelTaskSupport.compatibility(task: .anonymization, profile: plainSummary, hardware: hardware)
        XCTAssertEqual(anonymization.reasons, ["Модель не поддерживает эту задачу"])
        XCTAssertTrue(ModelTaskSupport.compatibility(task: .summary, profile: plainSummary, hardware: hardware).isCompatible)

        // A hardware-incompatible profile qualified for the task reports the
        // hardware reasons, never the task reason.
        let heavy = try makeProfile(id: "heavy", role: .summary, modelsRoot: modelsRoot,
                                    tasks: [.summary, .anonymization], memoryGB: 32)
        let reasons = ModelTaskSupport.compatibility(task: .anonymization, profile: heavy, hardware: hardware).reasons
        XCTAssertFalse(reasons.contains("Модель не поддерживает эту задачу"))
        XCTAssertFalse(reasons.isEmpty)

        // Each tab checks only its own task against the same profile.
        let partial = try makeProfile(id: "partial", role: .summary, modelsRoot: modelsRoot,
                                      tasks: [.summary, .anonymization])
        XCTAssertTrue(ModelTaskSupport.compatibility(task: .summary, profile: partial, hardware: hardware).isCompatible)
        XCTAssertTrue(ModelTaskSupport.compatibility(task: .anonymization, profile: partial, hardware: hardware).isCompatible)
        XCTAssertFalse(ModelTaskSupport.compatibility(task: .diagramRecognition, profile: partial, hardware: hardware).isCompatible)
    }

    func testLegacyFingerprintsDoNotChangeWithNewProfileFields() throws {
        let modelsRoot = try makeRoot().appendingPathComponent("models")
        let plain = try makeProfile(id: "summary-9b", role: .summary, modelsRoot: modelsRoot)
        let extended = try makeProfile(id: "summary-9b", role: .summary, modelsRoot: modelsRoot,
                                       tasks: Set(ModelTask.allCases), packageID: "pkg-x", limitBytes: 1000)
        // Pinned run fingerprints of audio and diagram jobs survive the added
        // catalog fields.
        XCTAssertEqual(ModelCatalog(models: [plain]).fingerprint, ModelCatalog(models: [extended]).fingerprint)
    }

    // MARK: - Verified installations

    func testScanVerifiesLocalInstallationsByPinnedFiles() throws {
        let root = try makeRoot()
        let modelsRoot = root.appendingPathComponent("models")
        let installed = try makeProfile(id: "shared-9b", role: .summary, modelsRoot: modelsRoot, contents: ["a", "b"])
        let missing = try makeProfile(id: "absent", role: .diagram, modelsRoot: modelsRoot, contents: ["c"], onDisk: false)
        // A member of the installed package whose own folder is absent.
        let sibling = try makeProfile(id: "shared-9b-vlm", role: .diagram, modelsRoot: modelsRoot,
                                      contents: ["a", "b"], onDisk: false)
        let catalog = ModelCatalog(models: [installed, missing, sibling])

        var verified = try ModelPackageRegistry.scanInstallations(catalog: catalog, modelsRoot: modelsRoot)
        XCTAssertEqual(Set(verified.keys), [installed.effectivePackageID])
        XCTAssertEqual(verified[installed.effectivePackageID]?.installedProfileID, "shared-9b")

        // A damaged file withdraws the installation of its package.
        try Data("tampered".utf8).write(to: modelsRoot.appendingPathComponent("shared-9b/file-0.bin"))
        verified = try ModelPackageRegistry.scanInstallations(catalog: catalog, modelsRoot: modelsRoot, verifyContents: true)
        XCTAssertTrue(verified.isEmpty)
    }

    func testScanReportsPresentDamagedFolderButNotAbsentMembers() throws {
        let root = try makeRoot()
        let modelsRoot = root.appendingPathComponent("models")
        let installed = try makeProfile(id: "shared-9b", role: .summary, modelsRoot: modelsRoot, contents: ["a"])
        // A sibling member of the same package with no folder of its own: it
        // is served by the verified sibling installation, never reported.
        let sibling = try makeProfile(id: "shared-9b-vlm", role: .diagram, modelsRoot: modelsRoot,
                                      contents: ["a"], onDisk: false)
        let absent = try makeProfile(id: "absent", role: .diagram, modelsRoot: modelsRoot, contents: ["c"], onDisk: false)
        let catalog = ModelCatalog(models: [installed, sibling, absent])

        // Same byte length ("a" → "b"), different SHA-256.
        try Data("b".utf8).write(to: modelsRoot.appendingPathComponent("shared-9b/file-0.bin"))
        let reported = InvalidProfileLog()
        let verified = try ModelPackageRegistry.scanInstallations(catalog: catalog, modelsRoot: modelsRoot,
                                                                  verifyContents: true) { reported.append($0, $1) }
        XCTAssertTrue(verified.isEmpty, "the damaged package loses its installation")
        XCTAssertEqual(reported.values.map(\.profile.id), ["shared-9b"],
                       "only the present but damaged folder is reported")
        XCTAssertTrue(reported.values[0].reason.contains("отсутствует или повреждён file-0.bin"),
                      "the reason names the damaged file: \(reported.values[0].reason)")
        // The damaged folder itself is never deleted by the scan.
        XCTAssertTrue(FileManager.default.fileExists(atPath: modelsRoot.appendingPathComponent("shared-9b/file-0.bin").path))
    }

    func testOneInstallationServesCompatibleAssignmentsOfTheSamePackage() async throws {
        let root = try makeRoot()
        let modelsRoot = root.appendingPathComponent("models")
        let member = try makeProfile(id: "shared-9b", role: .summary, modelsRoot: modelsRoot,
                                     contents: ["a", "b"], tasks: [.summary, .anonymization])
        // The anonymization slot points at a sibling profile with no folder of
        // its own: the single verified installation of the package serves it.
        let sibling = try makeProfile(id: "shared-9b-vlm", role: .diagram, modelsRoot: modelsRoot,
                                      contents: ["a", "b"], tasks: Set(ModelTask.allCases), onDisk: false)
        let catalog = ModelCatalog(models: [member, sibling])
        let registry = ModelPackageRegistry()
        let verified = try ModelPackageRegistry.scanInstallations(catalog: catalog, modelsRoot: modelsRoot)
        await registry.replaceInstallations(verified)

        var settings = AnonymizationSettings()
        settings.setProfile(sibling.id, for: .anonymization)
        let readiness = await registry.anonymizationReadiness(settings: settings, catalog: catalog, hardware: hardware)
        XCTAssertTrue(readiness.isReady)
        XCTAssertEqual(readiness.packageID, member.effectivePackageID)
        // The sibling slot needs no second download of the same files.
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelsRoot.appendingPathComponent(sibling.id).path))
        XCTAssertEqual(try catalog.verifiedModelFolder(for: sibling, at: modelsRoot).path,
                       modelsRoot.appendingPathComponent(member.id).path)

        // A present file of the expected size cannot substitute for a valid SHA.
        try Data("x".utf8).write(to: modelsRoot.appendingPathComponent("shared-9b/file-0.bin"))
        XCTAssertThrowsError(try catalog.verifiedModelFolder(for: sibling, at: modelsRoot))
    }

    // MARK: - Readiness matrix

    func testReadinessMatrixForIndependentTasks() throws {
        let modelsRoot = try makeRoot().appendingPathComponent("models")
        let summaryOnly = try makeProfile(id: "summary-9b", role: .summary, modelsRoot: modelsRoot, tasks: [.summary])
        let full = try makeProfile(id: "full", role: .summary, modelsRoot: modelsRoot, tasks: Set(ModelTask.allCases))
        let catalog = ModelCatalog(models: [summaryOnly, full])
        let ready: Set<String> = [full.effectivePackageID]

        // No assignment: an empty slot is not ready and needs nothing.
        var settings = AnonymizationSettings()
        var readiness = ModelAssignments.readiness(for: .anonymization, settings: settings, catalog: catalog,
                                                   hardware: hardware, readyPackageIDs: ready)
        XCTAssertTrue(readiness.noAssignment)
        XCTAssertFalse(readiness.isReady)
        XCTAssertFalse(readiness.waitingForInstall)

        // An assignment that no longer resolves in the catalog reads as empty.
        settings.setProfile("deleted-profile", for: .anonymization)
        readiness = ModelAssignments.readiness(for: .anonymization, settings: settings, catalog: catalog,
                                               hardware: hardware, readyPackageIDs: ready)
        XCTAssertTrue(readiness.noAssignment)

        // Compatible but not installed: the assignment is kept, jobs wait for
        // the package installation.
        settings.setProfile(full.id, for: .anonymization)
        readiness = ModelAssignments.readiness(for: .anonymization, settings: settings, catalog: catalog,
                                               hardware: hardware, readyPackageIDs: [])
        XCTAssertFalse(readiness.isReady)
        XCTAssertTrue(readiness.waitingForInstall)

        // Installed but not qualified for the task: incompatible with a reason.
        let installed = try makeProfile(id: "installed-summary", role: .summary, modelsRoot: modelsRoot,
                                        contents: ["x"], tasks: [.summary], packageID: "pkg-installed")
        let catalogWithInstalled = ModelCatalog(models: catalog.models + [installed])
        settings.setProfile(installed.id, for: .anonymization)
        readiness = ModelAssignments.readiness(for: .anonymization, settings: settings, catalog: catalogWithInstalled,
                                               hardware: hardware, readyPackageIDs: ["pkg-installed"])
        XCTAssertFalse(readiness.isReady)
        XCTAssertFalse(readiness.waitingForInstall)
        XCTAssertTrue(readiness.compatibility.reasons.contains("Модель не поддерживает эту задачу"))

        // Ready: assigned, qualified, installed.
        settings.setProfile(full.id, for: .anonymization)
        readiness = ModelAssignments.readiness(for: .anonymization, settings: settings, catalog: catalog,
                                               hardware: hardware, readyPackageIDs: ready)
        XCTAssertTrue(readiness.isReady)

        settings.setProfile(summaryOnly.id, for: .summary)
        readiness = ModelAssignments.readiness(for: .summary, settings: settings, catalog: catalog,
                                               hardware: hardware, readyPackageIDs: [summaryOnly.effectivePackageID])
        XCTAssertTrue(readiness.isReady)
        XCTAssertEqual(readiness.profile?.id, summaryOnly.id)
        XCTAssertEqual(settings.profileID(for: .anonymization), full.id)
    }

    // MARK: - Removal, readiness and leases

    func testRemovalSwitchesReadinessOffAndStartedJobsHoldThePackage() async throws {
        let root = try makeRoot()
        let modelsRoot = root.appendingPathComponent("models")
        let profile = try makeProfile(id: "full", role: .summary, modelsRoot: modelsRoot,
                                      contents: ["a"], tasks: Set(ModelTask.allCases))
        let catalog = ModelCatalog(models: [profile])
        let packageID = profile.effectivePackageID
        let registry = ModelPackageRegistry()
        await registry.replaceInstallations(try ModelPackageRegistry.scanInstallations(catalog: catalog, modelsRoot: modelsRoot))

        var settings = AnonymizationSettings()
        for task in ModelTask.allCases {
            settings.setProfile(profile.id, for: task)
        }
        var readiness = await registry.anonymizationReadiness(settings: settings, catalog: catalog, hardware: hardware)
        XCTAssertTrue(readiness.isReady)

        // Affected tabs of the removal under the saved settings.
        let plan = ModelPackageRegistry.removalPlan(packageID: packageID, settings: settings, catalog: catalog)
        XCTAssertEqual(plan.affectedTasks, Set(ModelTask.allCases))
        // A different package is unaffected.
        XCTAssertTrue(ModelPackageRegistry.removalPlan(packageID: "pkg-unknown", settings: settings, catalog: catalog)
            .affectedTasks.isEmpty)

        // A started job holds the verified package before the removal.
        let held = await registry.acquireLeaseIfReady(packageID: packageID, profileID: profile.id)
        let lease = try XCTUnwrap(held)
        // Admission after a confirmed removal finds no readiness.
        await registry.confirmRemoval(packageID: packageID)
        readiness = await registry.anonymizationReadiness(settings: settings, catalog: catalog, hardware: hardware)
        XCTAssertFalse(readiness.isReady)
        // The assignment itself survives; only readiness is gone.
        XCTAssertEqual(settings.profileID(for: .anonymization), profile.id)
        let rejected = await registry.acquireLeaseIfReady(packageID: packageID, profileID: profile.id)
        XCTAssertNil(rejected)
        // Physical deletion waits for the running job.
        let blockedWhileHeld = await registry.canPhysicallyRemove(packageID)
        XCTAssertFalse(blockedWhileHeld)
        let heldLeases = await registry.activeLeases(packageID: packageID)
        XCTAssertEqual(heldLeases.count, 1)
        // The lease keeps the pinned verified installation while it is held.
        XCTAssertEqual(lease.installation.installedProfileID, "full")

        // Worker exit releases the hold; the removal can complete.
        await registry.release(lease)
        let released = await registry.canPhysicallyRemove(packageID)
        XCTAssertTrue(released)
        try await registry.finishPhysicalRemoval(packageID: packageID)
        let finishedInstallation = await registry.installation(for: packageID)
        XCTAssertNil(finishedInstallation)
        let finishedReadiness = await registry.isReady(packageID)
        XCTAssertFalse(finishedReadiness)

        // A later publish after re-installation restores readiness.
        await registry.publishInstallation(packageID: packageID, profileID: profile.id)
        let restored = await registry.isReady(packageID)
        XCTAssertTrue(restored)
    }

    /// A cross-task completion flag of the deferred-removal waiter.
    private final class WaiterFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }

    /// The deferred physical removal of a confirmed removal waits for the last
    /// lease, wakes exactly when it closes, and a cancellation wakes it with
    /// `false` instead of deleting anything.
    func testDeferredPhysicalRemovalWaitsForTheLastLeaseAndWakesOnCancel() async throws {
        let root = try makeRoot()
        let modelsRoot = root.appendingPathComponent("models")
        let profile = try makeProfile(id: "full", role: .summary, modelsRoot: modelsRoot,
                                       contents: ["a"], tasks: Set(ModelTask.allCases))
        let packageID = profile.effectivePackageID
        let registry = ModelPackageRegistry()
        await registry.replaceInstallations(try ModelPackageRegistry.scanInstallations(
            catalog: ModelCatalog(models: [profile]), modelsRoot: modelsRoot))

        // A started job holds the package before the removal is confirmed.
        let held = await registry.acquireLeaseIfReady(packageID: packageID, profileID: profile.id)
        let lease = try XCTUnwrap(held)
        await registry.confirmRemoval(packageID: packageID)
        let completed = WaiterFlag()
        let deferred = Task { [registry, completed] in
            let removable = await registry.waitUntilPhysicallyRemovable(packageID: packageID)
            completed.set()
            return removable
        }
        // While the lease is alive the waiter must stay suspended.
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(completed.isSet)
        // Worker exit wakes the waiter with a removable package.
        await registry.release(lease)
        let afterRelease = await deferred.value
        XCTAssertTrue(afterRelease)
        let removable = await registry.canPhysicallyRemove(packageID)
        XCTAssertTrue(removable)
        try await registry.finishPhysicalRemoval(packageID: packageID)

        // A cancellation wakes a deferred waiter with `false`; the files stay.
        await registry.publishInstallation(packageID: packageID, profileID: profile.id)
        let reacquired = await registry.acquireLeaseIfReady(packageID: packageID, profileID: profile.id)
        XCTAssertNotNil(reacquired)
        await registry.confirmRemoval(packageID: packageID)
        let cancelled = Task { [registry] in
            await registry.waitUntilPhysicallyRemovable(packageID: packageID)
        }
        try await Task.sleep(for: .milliseconds(100))
        await registry.cancelRemoval(packageID: packageID)
        let afterCancel = await cancelled.value
        XCTAssertFalse(afterCancel)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: modelsRoot.appendingPathComponent(profile.id).appendingPathComponent("file-0.bin").path))
    }

    func testCanceledRemovalRestoresReadinessAndPublishIgnoresPendingRemoval() async throws {
        let root = try makeRoot()
        let modelsRoot = root.appendingPathComponent("models")
        let profile = try makeProfile(id: "full", role: .summary, modelsRoot: modelsRoot,
                                      contents: ["a"], tasks: Set(ModelTask.allCases))
        let packageID = profile.effectivePackageID
        let registry = ModelPackageRegistry()
        await registry.replaceInstallations(try ModelPackageRegistry.scanInstallations(
            catalog: ModelCatalog(models: [profile]), modelsRoot: modelsRoot))
        let initiallyReady = await registry.isReady(packageID)
        XCTAssertTrue(initiallyReady)

        // Cancel keeps the installation ready.
        await registry.confirmRemoval(packageID: packageID)
        let afterConfirm = await registry.isReady(packageID)
        XCTAssertFalse(afterConfirm)
        await registry.cancelRemoval(packageID: packageID)
        let afterCancel = await registry.isReady(packageID)
        XCTAssertTrue(afterCancel)

        // A publish cannot resurrect a package with a confirmed removal.
        await registry.confirmRemoval(packageID: packageID)
        await registry.publishInstallation(packageID: packageID, profileID: profile.id)
        let afterPendingPublish = await registry.isReady(packageID)
        XCTAssertFalse(afterPendingPublish)
        // Finishing without the confirmed removal still requires confirmation.
        do {
            try await registry.finishPhysicalRemoval(packageID: "pkg-other")
            XCTFail("An unconfirmed package removal must not finish")
        } catch {}
    }

    func testRemovalPlanCountsOnlyAssignmentsOfTheSamePackage() throws {
        let modelsRoot = try makeRoot().appendingPathComponent("models")
        let first = try makeProfile(id: "pkg-a-member", role: .summary, modelsRoot: modelsRoot, contents: ["a"])
        let second = try makeProfile(id: "pkg-b-member", role: .diagram, modelsRoot: modelsRoot, contents: ["b"])
        let catalog = ModelCatalog(models: [first, second])
        var settings = AnonymizationSettings()
        settings.setProfile(first.id, for: .summary)
        settings.setProfile(second.id, for: .diagramRecognition)
        settings.setProfile(first.id, for: .anonymization)

        XCTAssertEqual(ModelPackageRegistry.removalPlan(packageID: first.effectivePackageID, settings: settings, catalog: catalog)
            .affectedTasks, [.summary, .anonymization])
        XCTAssertEqual(ModelPackageRegistry.removalPlan(packageID: second.effectivePackageID, settings: settings, catalog: catalog)
            .affectedTasks, [.diagramRecognition])

        // A settings change between confirmation and execution changes the
        // list: the recomputed plan requires a fresh confirmation.
        settings.setProfile(nil, for: .summary)
        XCTAssertEqual(ModelPackageRegistry.removalPlan(packageID: first.effectivePackageID, settings: settings, catalog: catalog)
            .affectedTasks, [.anonymization])
    }

    // MARK: - Byte limit

    func testByteLimitSourcesOverrideCatalogAndConservativeCeiling() throws {
        let modelsRoot = try makeRoot().appendingPathComponent("models")
        let profile = try makeProfile(id: "full", role: .summary, modelsRoot: modelsRoot,
                                      contents: ["a"], tasks: Set(ModelTask.allCases))
        let limit = AnonymizationInputLimit()

        // Conservative default by the RAM/Metal working budget: the fixture's
        // usable budget is 12 GiB (16 GiB RAM with the system reserve, capped
        // by the 12 GiB Metal working set) — the smallest bucket.
        XCTAssertEqual(AnonymizationInputLimit.conservativeCeiling(for: hardware), 256 * 1024)
        let bigHardware = ModelHardware(chip: "Fixture Max", memoryBytes: 64 * 1_073_741_824, cpuCores: 16,
                                        gpuWorkingSetBytes: 48 * 1_073_741_824, appleSilicon: true, supportsMetal: true)
        XCTAssertEqual(AnonymizationInputLimit.conservativeCeiling(for: bigHardware), 1024 * 1024)
        let midHardware = ModelHardware(chip: "Fixture M3", memoryBytes: 24 * 1_073_741_824, cpuCores: 10,
                                        gpuWorkingSetBytes: 18 * 1_073_741_824, appleSilicon: true, supportsMetal: true)
        XCTAssertEqual(AnonymizationInputLimit.conservativeCeiling(for: midHardware), 512 * 1024)
        let noBudget = ModelHardware(chip: "Fixture Intel", memoryBytes: 16 * 1_073_741_824, cpuCores: 8,
                                     gpuWorkingSetBytes: 0, appleSilicon: false, supportsMetal: false)
        XCTAssertEqual(AnonymizationInputLimit.conservativeCeiling(for: noBudget), 0)

        XCTAssertEqual(limit.limitBytes(profile: profile, hardware: hardware), 256 * 1024)

        // A catalog value (qualification) is capped by this Mac's ceiling.
        let qualified = try makeProfile(id: "qualified", role: .summary, modelsRoot: modelsRoot,
                                        contents: ["a"], limitBytes: 8 * 1024 * 1024)
        XCTAssertEqual(limit.limitBytes(profile: qualified, hardware: hardware), 256 * 1024)
        XCTAssertEqual(limit.limitBytes(profile: qualified, hardware: bigHardware), 1024 * 1024)

        // Injected overrides win: the test and qualification seam.
        let overridden = AnonymizationInputLimit(overrides: [qualified.id: 42])
        XCTAssertEqual(overridden.limitBytes(profile: qualified, hardware: hardware), 42)
    }
}
