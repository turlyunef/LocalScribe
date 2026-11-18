import Foundation

/// Identity of one full immutable file set: pinned sizes and SHA-256 of every
/// file. Several profiles may reference one package; compatible assignments
/// share a single physical installation of it. The identity is stable and
/// independent of profile IDs, so runs pinned before a catalog update keep
/// their historical references.
public struct ModelPackage: Codable, Sendable, Identifiable {
    public let id: String
    /// Files in canonical order (local path, then SHA-256). The ordered list
    /// doubles as the file index for the loader boundary.
    public let files: [ModelFile]
    public let totalBytes: Int64

    /// Package identity is the id: derived ids hash the full pinned file set,
    /// so equal ids mean equal immutable contents.
    public static func == (lhs: ModelPackage, rhs: ModelPackage) -> Bool { lhs.id == rhs.id }
    public init(id: String, files: [ModelFile]) {
        self.id = id
        self.files = files.sorted { ($0.localPath, $0.sha256) < ($1.localPath, $1.sha256) }
        totalBytes = files.reduce(0) { $0 + $1.size }
    }
    /// The package of a profile: its explicit `packageID` reference, or the
    /// identity derived from the pinned files.
    public init(profile: ModelProfile) {
        self.init(id: profile.effectivePackageID, files: profile.files)
    }
    /// Content identity of a file set: sorted `path:size:sha256` triples. Two
    /// profiles share a package iff their pinned file sets are equal.
    public static func identity(ofFiles files: [ModelFile]) -> String {
        let canonical = files.map { "\($0.localPath):\($0.size):\($0.sha256)" }.sorted().joined(separator: "\n")
        return "pkg-" + Disk.fingerprint(canonical)
    }
}

/// Packages of a catalog with their member profiles, built from the pinned
/// files. Membership decides which profiles a single verified installation
/// serves.
public struct ModelPackageIndex: Sendable, Equatable {
    public let packages: [String: ModelPackage]
    public let profileIDsByPackage: [String: [String]]

    public static func == (lhs: ModelPackageIndex, rhs: ModelPackageIndex) -> Bool {
        lhs.profileIDsByPackage == rhs.profileIDsByPackage
    }
    public init(catalog: ModelCatalog) {
        var packages: [String: ModelPackage] = [:]
        var members: [String: Set<String>] = [:]
        for profile in catalog.models {
            let package = ModelPackage(profile: profile)
            packages[package.id] = package
            members[package.id, default: []].insert(profile.id)
        }
        self.packages = packages
        profileIDsByPackage = members.mapValues { $0.sorted() }
    }
    public func package(withID id: String) -> ModelPackage? { packages[id] }
    public func memberProfileIDs(of packageID: String) -> [String] { profileIDsByPackage[packageID] ?? [] }
    public func contains(profile: ModelProfile) -> Bool {
        packages[profile.effectivePackageID] != nil
    }
}

/// A published verified installation of a package: one member profile whose
/// pinned files fully verified on disk. The installation survives catalog
/// reloads only through re-verification (scan) or a new verified publish.
public struct ModelPackageInstallation: Codable, Sendable, Equatable {
    public let packageID: String
    /// The profile that physically owns the verified folder under the models
    /// root; file requests resolve through the package index.
    public let installedProfileID: String
    public let verifiedAt: Date
    public init(packageID: String, installedProfileID: String, verifiedAt: Date = Date()) {
        self.packageID = packageID; self.installedProfileID = installedProfileID; self.verifiedAt = verifiedAt
    }
}

/// Access of one started job to a verified package. Held from admission until
/// the worker exits; a confirmed removal waits for all leases to close before
/// any physical deletion.
public struct ModelPackageLease: Sendable, Equatable {
    public let id: UUID
    public let packageID: String
    public let profileID: String
    /// The installation the lease pinned: its files stay intact and complete
    /// for the whole run, even while a removal is already confirmed.
    public let installation: ModelPackageInstallation
    init(packageID: String, profileID: String, installation: ModelPackageInstallation) {
        id = UUID(); self.packageID = packageID; self.profileID = profileID; self.installation = installation
    }
}

/// Tabs affected by removing one package, computed from the saved assignments.
/// The library recomputes the plan before confirmation; a changed list
/// requires a fresh confirmation.
public struct ModelPackageRemovalPlan: Sendable, Equatable {
    public let packageID: String
    public let affectedTasks: Set<ModelTask>
    public var affectsAnything: Bool { !affectedTasks.isEmpty }
}

/// Single serialized owner of package installations, their readiness and the
/// file-hold leases of started jobs. Physical deletion itself is integrated by
/// works 9 and 11; this actor only guarantees the hold model: a confirmed
/// removal switches readiness off for new jobs at once, while started jobs
/// keep their pinned verified files until the worker exits.
public actor ModelPackageRegistry {
    private var installations: [String: ModelPackageInstallation] = [:]
    private var removalsPending: Set<String> = []
    private var leases: [UUID: ModelPackageLease] = [:]
    /// Deferred physical removals waiting for the last lease of their package.
    private var removalWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    public init() {}

    /// Verify local installations from the models root: for every package the
    /// first member profile (in catalog order) whose pinned files fully verify
    /// on disk publishes the installation. Existing in-memory state is
    /// replaced with the verified result; heavy I/O belongs off the main
    /// actor, like `ModelLibrary.load`.
    public static func scanInstallations(catalog: ModelCatalog, modelsRoot: URL,
                                         verifyContents: Bool = true) throws -> [String: ModelPackageInstallation] {
        var verified = [String: ModelPackageInstallation]()
        for profile in catalog.models {
            guard (try? profile.validateFiles(at: modelsRoot, verifyContents: verifyContents)) != nil else { continue }
            let packageID = profile.effectivePackageID
            if verified[packageID] == nil {
                verified[packageID] = ModelPackageInstallation(packageID: packageID, installedProfileID: profile.id)
            }
        }
        return verified
    }

    /// Replace the whole installation state (startup scan result).
    public func replaceInstallations(_ verified: [String: ModelPackageInstallation]) {
        installations = verified
    }

    /// Publish one freshly verified installation (after a completed download).
    /// The first member of the package wins; publishing never resurrects a
    /// package with a confirmed pending removal.
    public func publishInstallation(packageID: String, profileID: String) {
        guard !removalsPending.contains(packageID) else { return }
        if installations[packageID] == nil {
            installations[packageID] = ModelPackageInstallation(packageID: packageID, installedProfileID: profileID)
        }
    }

    public func installation(for packageID: String) -> ModelPackageInstallation? {
        installations[packageID]
    }

    /// A package counts as ready when a verified installation exists and no
    /// removal of it is confirmed.
    public func isReady(_ packageID: String) -> Bool {
        installations[packageID] != nil && !removalsPending.contains(packageID)
    }

    /// All packages ready for new jobs.
    public func readyPackageIDs() -> Set<String> {
        Set(installations.keys).subtracting(removalsPending)
    }

    // MARK: - Leases

    /// Admission of one job: acquire the verified package only while it is
    /// ready for new jobs. The serialized actor keeps the check and the
    /// acquisition atomic against a concurrent removal confirmation.
    public func acquireLeaseIfReady(packageID: String, profileID: String) -> ModelPackageLease? {
        guard isReady(packageID), let installation = installations[packageID] else { return nil }
        let lease = ModelPackageLease(packageID: packageID, profileID: profileID, installation: installation)
        leases[lease.id] = lease
        return lease
    }

    /// Worker exit: idempotent release. Closing the last lease of a package
    /// with a confirmed removal makes it physically removable and wakes the
    /// deferred physical removal waiting for it.
    public func release(_ lease: ModelPackageLease) {
        leases[lease.id] = nil
        if removalsPending.contains(lease.packageID), activeLeases(packageID: lease.packageID).isEmpty {
            resumeRemovalWaiters(lease.packageID)
        }
    }

    public func activeLeases(packageID: String) -> [ModelPackageLease] {
        leases.values.filter { $0.packageID == packageID }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    // MARK: - Removal

    /// The affected tabs of a removal under the saved settings. Recompute at
    /// confirmation time; a changed list needs a fresh confirmation.
    public static func removalPlan(packageID: String, settings: AnonymizationSettings, catalog: ModelCatalog) -> ModelPackageRemovalPlan {
        ModelPackageRemovalPlan(packageID: packageID,
                                affectedTasks: ModelAssignments.affectedTasks(packageID: packageID, settings: settings, catalog: catalog))
    }

    /// Confirmed removal: readiness for new jobs switches off immediately, the
    /// assigned profiles stay selected, and started jobs keep their leases
    /// until the workers exit.
    public func confirmRemoval(packageID: String) {
        guard installations[packageID] != nil else { return }
        removalsPending.insert(packageID)
    }

    /// Cancellation restores readiness until the physical removal runs. A
    /// deferred removal waiting for leases wakes up and re-checks.
    public func cancelRemoval(packageID: String) {
        removalsPending.remove(packageID)
        resumeRemovalWaiters(packageID)
    }

    public func isRemovalPending(_ packageID: String) -> Bool {
        removalsPending.contains(packageID)
    }

    /// A confirmed removal may physically delete the files only after the last
    /// lease of the package has closed. Callers check this (or wait through
    /// `waitUntilPhysicallyRemovable`) before touching any file.
    public func canPhysicallyRemove(_ packageID: String) -> Bool {
        removalsPending.contains(packageID) && activeLeases(packageID: packageID).isEmpty
    }

    /// Wait until a confirmed removal may physically delete the files: the
    /// last lease of the package has closed. Readiness is already off after
    /// `confirmRemoval`, so no new lease can open while the caller waits and
    /// the package stays removable once the wait returns `true`. Returns
    /// `false` without waiting when no removal of the package is confirmed;
    /// a cancellation also wakes the waiter with `false`.
    public func waitUntilPhysicallyRemovable(packageID: String) async -> Bool {
        if canPhysicallyRemove(packageID) { return true }
        guard removalsPending.contains(packageID) else { return false }
        await withCheckedContinuation { continuation in
            removalWaiters[packageID, default: []].append(continuation)
        }
        return canPhysicallyRemove(packageID)
    }

    /// Wakes the deferred physical removals of a package (its last lease
    /// closed or the removal was cancelled); the woken caller re-checks
    /// `canPhysicallyRemove`.
    private func resumeRemovalWaiters(_ packageID: String) {
        for continuation in removalWaiters.removeValue(forKey: packageID) ?? [] { continuation.resume() }
    }

    /// Finalize the physical deletion (works 9/11 call it after removing the
    /// files): forgets the installation and the confirmed removal. Requires
    /// zero active leases.
    public func finishPhysicalRemoval(packageID: String) throws {
        guard removalsPending.contains(packageID) else {
            throw ScribeError.message("Удаление комплекта не подтверждено")
        }
        guard activeLeases(packageID: packageID).isEmpty else {
            throw ScribeError.message("Комплект ещё используется запущенной задачей")
        }
        removalsPending.remove(packageID)
        installations[packageID] = nil
        resumeRemovalWaiters(packageID)
    }

    // MARK: - Resolution on the actor

    /// Atomic readiness of the anonymization assignment: the caller cannot
    /// observe a torn state between the check and the lease acquisition.
    public func anonymizationReadiness(settings: AnonymizationSettings, catalog: ModelCatalog,
                                       hardware: ModelHardware) -> ModelTaskReadiness {
        ModelAssignments.readiness(for: .anonymization, settings: settings, catalog: catalog,
                                   hardware: hardware, readyPackageIDs: readyPackageIDs())
    }

    public struct Snapshot: Sendable, Equatable {
        public let installations: [ModelPackageInstallation]
        public let removalsPending: Set<String>
        public let activeLeasesByPackage: [String: Int]
    }
    public func snapshot() -> Snapshot {
        Snapshot(installations: installations.values.sorted { $0.packageID < $1.packageID },
                 removalsPending: removalsPending,
                 activeLeasesByPackage: Dictionary(grouping: leases.values, by: \.packageID).mapValues(\.count))
    }
}
