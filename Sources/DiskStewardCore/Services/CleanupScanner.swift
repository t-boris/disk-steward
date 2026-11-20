import Foundation

/// Automatically discovers cleanup opportunities across archived originals, user files, caches,
/// Docker artifacts, and node_modules directories without modifying any data (REQ-006, DEC-003, plan I-8).
public struct CleanupScanner: Sendable {
    private let dockerInspector: DockerInspector
    private let homeDirectory: String

    /// Sub-entries inside ~/Library/Caches that must NEVER be proposed for cleanup.
    private static let excludedCacheNames: Set<String> = [
        "com.apple.bird",
        "com.apple.cloudd",
        "com.apple.icloud.fmfd",
        "com.apple.nsurlsessiond",
        "com.apple.Safari",
        "com.apple.security",
        "CloudKit",
        "FamilyCircle",
        "GeoServices",
        "com.disksteward.app",
        "DiskSteward"
    ]

    public init(
        dockerInspector: DockerInspector = DockerInspector(),
        homeDirectory: String = NSHomeDirectory()
    ) {
        self.dockerInspector = dockerInspector
        self.homeDirectory = homeDirectory
    }

    /// Generates a read-only CleanupProposal containing all discovered cleanup opportunities.
    public func discoverProposals(
        configuration: AppConfiguration,
        verifiedArchives: [VerifiedArchiveRecord],
        now: Date = Date()
    ) async -> CleanupProposal {
        var candidates: [CleanupCandidate] = []
        var notes: [String] = []
        var archivedSourcePaths: Set<String> = []

        // 1. Verified Archived Originals (only proposed if archive copy currently exists and passes SHA-256!)
        let archivedCandidates = discoverVerifiedArchivedOriginals(
            records: verifiedArchives,
            notes: &notes
        )
        for item in archivedCandidates {
            archivedSourcePaths.insert(item.location)
        }
        candidates.append(contentsOf: archivedCandidates)

        // 2. Large & Old User Files (Downloads, Desktop, etc.)
        let userFileCandidates = discoverUserFiles(
            roots: configuration.cleanupUserFileRoots,
            largeFileThresholdBytes: configuration.cleanupLargeFileThresholdBytes,
            oldInstallerAgeDays: configuration.cleanupOldInstallerAgeDays,
            excludingPaths: archivedSourcePaths,
            now: now
        )
        candidates.append(contentsOf: userFileCandidates)

        // 3. Caches (user & developer caches, strictly excluding system-critical caches)
        if configuration.includeCacheCleanup {
            let cacheCandidates = discoverCaches(homeDirectory: homeDirectory)
            candidates.append(contentsOf: cacheCandidates)
        }

        // 4. node_modules directories under development roots
        let nodeModulesCandidates = discoverNodeModules(roots: configuration.nodeModulesSearchRoots)
        candidates.append(contentsOf: nodeModulesCandidates)

        // 5. Docker artifacts (images, stopped containers, dangling volumes, build cache)
        var dockerStatus: String?
        if configuration.includeDockerCleanup {
            let dockerResult = await dockerInspector.discoverArtifacts()
            dockerStatus = dockerResult.statusMessage
            candidates.append(contentsOf: dockerResult.candidates)
        } else {
            dockerStatus = "Docker cleanup inspection is disabled in settings."
        }

        // Deduplicate by ID and sort largest first within each category.
        var seenIDs: Set<String> = []
        let unique = candidates.filter { seenIDs.insert($0.id).inserted }
            .sorted { lhs, rhs in
                if lhs.category != rhs.category {
                    return CleanupCategory.allCases.firstIndex(of: lhs.category)! < CleanupCategory.allCases.firstIndex(of: rhs.category)!
                }
                return lhs.estimatedReclaimableBytes > rhs.estimatedReclaimableBytes
            }

        return CleanupProposal(
            createdAt: now,
            candidates: unique,
            notes: notes,
            dockerStatusMessage: dockerStatus
        )
    }

    private func discoverVerifiedArchivedOriginals(
        records: [VerifiedArchiveRecord],
        notes: inout [String]
    ) -> [CleanupCandidate] {
        let fm = FileManager.default
        var results: [CleanupCandidate] = []
        var skippedUnmounted = 0

        for record in records {
            let srcURL = URL(fileURLWithPath: record.sourcePath)
            let dstURL = URL(fileURLWithPath: record.destinationPath)

            // Skip originals already removed.
            guard fm.fileExists(atPath: srcURL.path) else { continue }

            // Archive destination must be currently mounted/present to verify integrity (DEC-007).
            guard fm.fileExists(atPath: dstURL.path) else {
                skippedUnmounted += 1
                continue
            }

            guard let srcValues = try? srcURL.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey]),
                  let srcHash = try? FileHasher.sha256(of: srcURL),
                  let dstHash = try? FileHasher.sha256(of: dstURL),
                  srcHash == record.sha256,
                  dstHash == record.sha256 else {
                continue
            }

            let fileSize = Int64(srcValues.fileSize ?? 0)
            let allocated = Int64(srcValues.totalFileAllocatedSize ?? srcValues.fileSize ?? 0)
            let modDate = srcValues.contentModificationDate ?? record.sourceModifiedDate

            results.append(
                CleanupCandidate(
                    id: "archived:\(srcURL.standardizedFileURL.path)",
                    category: .archivedOriginals,
                    title: srcURL.lastPathComponent,
                    location: srcURL.standardizedFileURL.path,
                    estimatedReclaimableBytes: allocated,
                    reason: "Verified SHA-256 copy exists at \(dstURL.path)",
                    lastModified: modDate,
                    isDirectory: false,
                    verifiedArchiveRecord: record,
                    snapshotFileSize: fileSize,
                    snapshotModifiedDate: modDate
                )
            )
        }

        if skippedUnmounted > 0 {
            notes.append("\(skippedUnmounted) archived original(s) are hidden because their archive disk is currently disconnected and cannot be verified.")
        }

        return results
    }

    private func discoverUserFiles(
        roots: [String],
        largeFileThresholdBytes: Int64,
        oldInstallerAgeDays: Int,
        excludingPaths: Set<String>,
        now: Date
    ) -> [CleanupCandidate] {
        let fm = FileManager.default
        var results: [CleanupCandidate] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey]

        for rootPath in roots {
            let rootURL = URL(fileURLWithPath: rootPath).standardizedFileURL
            guard fm.fileExists(atPath: rootURL.path),
                  let enumerator = fm.enumerator(
                      at: rootURL,
                      includingPropertiesForKeys: keys,
                      options: [.skipsHiddenFiles, .skipsPackageDescendants]
                  ) else {
                continue
            }

            for case let fileURL as URL in enumerator {
                let path = fileURL.standardizedFileURL.path
                if excludingPaths.contains(path) { continue }
                guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true,
                      values.isSymbolicLink != true else {
                    continue
                }

                let logicalSize = Int64(values.fileSize ?? 0)
                let allocated = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
                let modDate = values.contentModificationDate ?? now
                let ageDays = max(0, Int(now.timeIntervalSince(modDate) / 86_400))
                let category = FileCategory.classify(url: fileURL, isDirectory: false)

                let isLargeFile = allocated >= largeFileThresholdBytes
                let isOldInstaller = (category == .installers && ageDays >= oldInstallerAgeDays && allocated >= 5_000_000)

                guard isLargeFile || isOldInstaller else { continue }

                let reason: String
                if isOldInstaller && isLargeFile {
                    reason = "Large installer (\(ByteFormatting.string(from: allocated))), last modified \(ageDays) day(s) ago"
                } else if isOldInstaller {
                    reason = "Installer file last modified \(ageDays) day(s) ago"
                } else {
                    reason = "Large file (\(ByteFormatting.string(from: allocated))), last modified \(ageDays) day(s) ago"
                }

                results.append(
                    CleanupCandidate(
                        id: "file:\(path)",
                        category: .userFiles,
                        title: fileURL.lastPathComponent,
                        location: path,
                        estimatedReclaimableBytes: allocated,
                        reason: reason,
                        lastModified: modDate,
                        isDirectory: false,
                        snapshotFileSize: logicalSize,
                        snapshotModifiedDate: modDate
                    )
                )
            }
        }
        return results
    }

    private func discoverCaches(homeDirectory: String) -> [CleanupCandidate] {
        let fm = FileManager.default
        var results: [CleanupCandidate] = []
        let minimumCacheBytes: Int64 = 5_000_000 // Ignore tiny < 5 MB caches to reduce noise.

        // Named developer caches
        let namedCaches: [(title: String, relativePath: String, reason: String)] = [
            ("Xcode DerivedData", "Library/Developer/Xcode/DerivedData", "Reproducible Xcode build products and indexes"),
            ("Homebrew Cache", "Library/Caches/Homebrew", "Downloaded Homebrew bottles and archives"),
            ("npm Cache", ".npm/_cacache", "Cached npm packages (re-downloaded on demand)"),
            ("Yarn Cache", "Library/Caches/Yarn", "Cached Yarn packages"),
            ("pip Cache", "Library/Caches/pip", "Cached Python wheel downloads"),
            ("pnpm Store Cache", "Library/pnpm/store", "Cached pnpm packages")
        ]

        var alreadyScannedPaths: Set<String> = []

        for spec in namedCaches {
            let fullPath = (homeDirectory as NSString).appendingPathComponent(spec.relativePath)
            let url = URL(fileURLWithPath: fullPath).standardizedFileURL
            guard fm.fileExists(atPath: url.path) else { continue }
            alreadyScannedPaths.insert(url.path)

            let (size, latestDate) = directorySizeAndDate(at: url)
            guard size >= minimumCacheBytes else { continue }
            results.append(
                CleanupCandidate(
                    id: "cache:\(url.path)",
                    category: .caches,
                    title: spec.title,
                    location: url.path,
                    estimatedReclaimableBytes: size,
                    reason: spec.reason,
                    lastModified: latestDate,
                    isDirectory: true
                )
            )
        }

        // Top-level entries inside ~/Library/Caches (skipping protected Apple/system/self caches)
        let libraryCaches = URL(fileURLWithPath: homeDirectory).appendingPathComponent("Library/Caches").standardizedFileURL
        if let entries = try? fm.contentsOfDirectory(
            at: libraryCaches,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            for entry in entries {
                let stdPath = entry.standardizedFileURL.path
                if alreadyScannedPaths.contains(stdPath) { continue }
                let name = entry.lastPathComponent
                if Self.excludedCacheNames.contains(name) || name.hasPrefix("com.apple.") {
                    continue
                }
                let (size, latestDate) = directorySizeAndDate(at: entry)
                guard size >= minimumCacheBytes else { continue }
                results.append(
                    CleanupCandidate(
                        id: "cache:\(stdPath)",
                        category: .caches,
                        title: "App Cache: \(name)",
                        location: stdPath,
                        estimatedReclaimableBytes: size,
                        reason: "Application cache folder under ~/Library/Caches",
                        lastModified: latestDate,
                        isDirectory: true
                    )
                )
            }
        }

        return results
    }

    private func discoverNodeModules(roots: [String]) -> [CleanupCandidate] {
        let fm = FileManager.default
        var results: [CleanupCandidate] = []
        var visitedRoots: Set<String> = []

        for rootPath in roots {
            let rootURL = URL(fileURLWithPath: rootPath).standardizedFileURL
            guard visitedRoots.insert(rootURL.path).inserted, fm.fileExists(atPath: rootURL.path) else {
                continue
            }

            guard let enumerator = fm.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
                options: [.skipsPackageDescendants]
            ) else {
                continue
            }

            for case let url as URL in enumerator {
                let name = url.lastPathComponent
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
                if values?.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    continue
                }
                guard values?.isDirectory == true else { continue }

                if name == ".git" || name == ".build" || name == "DerivedData" || name == ".Trash" {
                    enumerator.skipDescendants()
                    continue
                }

                if name == "node_modules" {
                    // Never descend into nested node_modules.
                    enumerator.skipDescendants()
                    let (size, latestDate) = directorySizeAndDate(at: url)
                    let projectName = url.deletingLastPathComponent().lastPathComponent
                    results.append(
                        CleanupCandidate(
                            id: "node_modules:\(url.standardizedFileURL.path)",
                            category: .nodeModules,
                            title: "\(projectName)/node_modules",
                            location: url.standardizedFileURL.path,
                            estimatedReclaimableBytes: size,
                            reason: "Reinstallable Node.js dependencies for project '\(projectName)'",
                            lastModified: latestDate ?? values?.contentModificationDate,
                            isDirectory: true
                        )
                    )
                }
            }
        }
        return results
    }

    private func directorySizeAndDate(at url: URL) -> (Int64, Date?) {
        let fm = FileManager.default
        var total: Int64 = 0
        var latestDate: Date? = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)

        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey],
            options: []
        ) else {
            return (0, latestDate)
        }

        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey]
            ) else { continue }

            if values.isSymbolicLink == true { continue }
            if values.isRegularFile == true {
                total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            }
            if let mod = values.contentModificationDate {
                if latestDate == nil || mod > latestDate! {
                    latestDate = mod
                }
            }
        }
        return (total, latestDate)
    }
}
