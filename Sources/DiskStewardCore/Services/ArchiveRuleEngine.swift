import Foundation

/// Evaluates user-defined classification rules (file type, file name, source folder) and plans
/// non-destructive destination routing with SHA-256 collision analysis (REQ-005, DEC-002, DEC-007, DEC-008, plan I-5).
public struct ArchiveRuleEngine: Sendable {
    public init() {}

    /// Evaluates ordered rules top-to-bottom and returns the first enabled matching rule, or nil.
    public func matchingRule(
        for fileURL: URL,
        category: FileCategory,
        in rules: [ArchiveRule]
    ) -> ArchiveRule? {
        let standardizedPath = fileURL.standardizedFileURL.path
        let fileName = fileURL.lastPathComponent
        let fileExt = fileURL.pathExtension.lowercased()

        for rule in rules where rule.isEnabled {
            if matches(
                rule: rule,
                standardizedFilePath: standardizedPath,
                fileName: fileName,
                fileExtension: fileExt,
                category: category
            ) {
                return rule
            }
        }
        return nil
    }

    private func matches(
        rule: ArchiveRule,
        standardizedFilePath: String,
        fileName: String,
        fileExtension: String,
        category: FileCategory
    ) -> Bool {
        // 1. Source folder condition (optional)
        if let sourceFilter = rule.sourceFolderPath, !sourceFilter.isEmpty {
            let standardizedPrefix = URL(fileURLWithPath: sourceFilter).standardizedFileURL.path
            let matchesFolder = standardizedFilePath == standardizedPrefix
                || standardizedFilePath.hasPrefix(standardizedPrefix + "/")
            if !matchesFolder { return false }
        }

        // 2. File type condition (categories OR custom extensions; empty means any type)
        let hasTypeCondition = !rule.fileCategories.isEmpty || !rule.customExtensions.isEmpty
        if hasTypeCondition {
            let matchesCategory = rule.fileCategories.contains(category)
            let matchesExt = !fileExtension.isEmpty && rule.customExtensions.contains(fileExtension)
            if !matchesCategory && !matchesExt { return false }
        }

        // 3. File name condition (optional)
        let trimmedPattern = rule.fileNamePattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if rule.fileNameMatchMode != .any && !trimmedPattern.isEmpty {
            let lowerName = fileName.lowercased()
            let lowerPattern = trimmedPattern.lowercased()
            switch rule.fileNameMatchMode {
            case .any:
                break
            case .contains:
                if !lowerName.contains(lowerPattern) { return false }
            case .startsWith:
                if !lowerName.hasPrefix(lowerPattern) { return false }
            case .endsWith:
                if !lowerName.hasSuffix(lowerPattern) { return false }
            case .glob:
                if !Self.matchesGlob(text: lowerName, pattern: lowerPattern) { return false }
            }
        }

        return true
    }

    /// Wildcard glob matcher supporting `*` (0+ chars) and `?` (1 char).
    public static func matchesGlob(text: String, pattern: String) -> Bool {
        var regex = "^"
        for ch in pattern {
            switch ch {
            case "*":
                regex += ".*"
            case "?":
                regex += "."
            case ".", "\\", "+", "(", ")", "[", "]", "{", "}", "^", "$", "|":
                regex += "\\\(ch)"
            default:
                regex.append(ch)
            }
        }
        regex += "$"
        return text.range(of: regex, options: .regularExpression) != nil
    }

    /// Builds a dry-run classified archive plan for `job` without modifying any files (plan I-5).
    public func buildPlan(
        for job: ArchiveJob,
        mountedVolumePaths: Set<String>? = nil
    ) -> ArchivePlan {
        let fm = FileManager.default
        var entries: [ArchivePlanEntry] = []
        var unavailableDestinations: Set<String> = []
        var scanErrors: [String] = []
        var claimedDestinations: [String: String] = [:] // destPath -> sourceSHA256 (if computed)

        for sourceFolder in job.sourceFolders {
            let rootURL = URL(fileURLWithPath: sourceFolder).standardizedFileURL
            guard fm.fileExists(atPath: rootURL.path) else {
                scanErrors.append("Source folder does not exist: \(rootURL.path)")
                continue
            }

            let files = collectSourceFiles(
                rootURL: rootURL,
                includeSubdirectories: job.includeSubdirectories,
                skipHiddenFiles: job.skipHiddenFiles,
                scanErrors: &scanErrors
            )

            for fileURL in files {
                let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
                let fileSize = Int64(values?.fileSize ?? values?.totalFileAllocatedSize ?? 0)
                let category = FileCategory.classify(url: fileURL, isDirectory: false)

                let matchedRule = matchingRule(for: fileURL, category: category, in: job.rules)
                let destFolder: String?
                let matchedName: String?
                let preserveRelative: Bool

                if let rule = matchedRule {
                    destFolder = rule.destinationFolderPath
                    matchedName = rule.name
                    preserveRelative = rule.preserveRelativeSubpath
                } else if let fallback = job.fallbackDestinationPath, !fallback.isEmpty {
                    destFolder = fallback
                    matchedName = "Fallback Destination"
                    preserveRelative = false
                } else {
                    // DEC-008: Unmatched files remain untouched when no fallback folder is configured.
                    entries.append(
                        ArchivePlanEntry(
                            sourcePath: fileURL.path,
                            sourceRootPath: rootURL.path,
                            fileName: fileURL.lastPathComponent,
                            fileSize: fileSize,
                            category: category,
                            matchedRuleName: nil,
                            destinationPath: nil,
                            action: .skipUnmatched,
                            note: "No classification rule matched and no fallback folder is configured"
                        )
                    )
                    continue
                }

                guard let destinationBase = destFolder else { continue }

                // Check destination volume availability (DEC-004).
                if !VolumeMonitor.isDestinationVolumeAvailable(destinationBase, mountedVolumePaths: mountedVolumePaths) {
                    unavailableDestinations.insert(destinationBase)
                    entries.append(
                        ArchivePlanEntry(
                            sourcePath: fileURL.path,
                            sourceRootPath: rootURL.path,
                            fileName: fileURL.lastPathComponent,
                            fileSize: fileSize,
                            category: category,
                            matchedRuleName: matchedName,
                            destinationPath: destinationBase,
                            action: .destinationUnavailable,
                            note: "Destination disk is currently unavailable"
                        )
                    )
                    continue
                }

                let targetDirURL = computeTargetDirectory(
                    destinationBase: destinationBase,
                    fileURL: fileURL,
                    sourceRootURL: rootURL,
                    preserveRelativeSubpath: preserveRelative
                )
                let initialDestURL = targetDirURL.appendingPathComponent(fileURL.lastPathComponent)

                // Collision resolution (DEC-007)
                let resolution = resolveDestination(
                    sourceURL: fileURL,
                    desiredDestinationURL: initialDestURL,
                    claimedDestinations: &claimedDestinations
                )

                entries.append(
                    ArchivePlanEntry(
                        sourcePath: fileURL.path,
                        sourceRootPath: rootURL.path,
                        fileName: fileURL.lastPathComponent,
                        fileSize: fileSize,
                        category: category,
                        matchedRuleName: matchedName,
                        destinationPath: resolution.destinationURL.path,
                        action: resolution.action,
                        note: resolution.note
                    )
                )
            }
        }

        // Also inspect configured destination paths even when no files currently matched,
        // so unavailable external archive disks are still surfaced clearly.
        for dest in job.configuredDestinations {
            if !VolumeMonitor.isDestinationVolumeAvailable(dest, mountedVolumePaths: mountedVolumePaths) {
                unavailableDestinations.insert(dest)
            }
        }

        return ArchivePlan(
            jobID: job.id,
            jobName: job.name,
            entries: entries,
            unavailableDestinations: Array(unavailableDestinations).sorted(),
            scanErrors: scanErrors
        )
    }

    public struct DestinationResolution: Sendable {
        public let destinationURL: URL
        public let action: ArchivePlannedAction
        public let matchedExistingSHA256: String?
        public let note: String?
    }

    /// Resolves destination filename collisions per DEC-007:
    /// - If destination does not exist (and isn't claimed in this batch): `.copy`
    /// - If existing file has identical SHA-256: `.skipDuplicate`
    /// - If existing file differs: generates unique numeric suffix `name (2).ext`, `name (3).ext`, ...
    public func resolveDestination(
        sourceURL: URL,
        desiredDestinationURL: URL,
        sourceSHA256: String? = nil,
        claimedDestinations: inout [String: String]
    ) -> DestinationResolution {
        let fm = FileManager.default
        let desiredPath = desiredDestinationURL.standardizedFileURL.path

        if !fm.fileExists(atPath: desiredPath) && claimedDestinations[desiredPath] == nil {
            claimedDestinations[desiredPath] = sourceSHA256 ?? ""
            return DestinationResolution(
                destinationURL: desiredDestinationURL,
                action: .copy,
                matchedExistingSHA256: nil,
                note: nil
            )
        }

        let computedSourceHash: String?
        if let provided = sourceSHA256 {
            computedSourceHash = provided
        } else {
            computedSourceHash = try? FileHasher.sha256(of: sourceURL)
        }

        // Check desired path first for exact SHA-256 match.
        if let srcHash = computedSourceHash {
            if fm.fileExists(atPath: desiredPath),
               let existingHash = try? FileHasher.sha256(of: desiredDestinationURL),
               existingHash == srcHash {
                return DestinationResolution(
                    destinationURL: desiredDestinationURL,
                    action: .skipDuplicate,
                    matchedExistingSHA256: existingHash,
                    note: "Identical file already exists in destination (SHA-256 verified)"
                )
            }
            if let claimedHash = claimedDestinations[desiredPath], !claimedHash.isEmpty, claimedHash == srcHash {
                return DestinationResolution(
                    destinationURL: desiredDestinationURL,
                    action: .skipDuplicate,
                    matchedExistingSHA256: claimedHash,
                    note: "Identical file already scheduled for this destination in the same run"
                )
            }
        }

        // Different content: search numbered suffixes `name (2).ext`, `name (3).ext`, ...
        let dirURL = desiredDestinationURL.deletingLastPathComponent()
        let ext = desiredDestinationURL.pathExtension
        let baseName = ext.isEmpty
            ? desiredDestinationURL.lastPathComponent
            : desiredDestinationURL.deletingPathExtension().lastPathComponent

        var index = 2
        while index < 10_000 {
            let candidateName = ext.isEmpty ? "\(baseName) (\(index))" : "\(baseName) (\(index)).\(ext)"
            let candidateURL = dirURL.appendingPathComponent(candidateName)
            let candidatePath = candidateURL.standardizedFileURL.path

            if fm.fileExists(atPath: candidatePath) {
                if let srcHash = computedSourceHash,
                   let existingHash = try? FileHasher.sha256(of: candidateURL),
                   existingHash == srcHash {
                    return DestinationResolution(
                        destinationURL: candidateURL,
                        action: .skipDuplicate,
                        matchedExistingSHA256: existingHash,
                        note: "Identical copy already exists as \(candidateName) (SHA-256 verified)"
                    )
                }
                index += 1
                continue
            }

            if claimedDestinations[candidatePath] != nil {
                if let srcHash = computedSourceHash, claimedDestinations[candidatePath] == srcHash {
                    return DestinationResolution(
                        destinationURL: candidateURL,
                        action: .skipDuplicate,
                        matchedExistingSHA256: srcHash,
                        note: "Identical file already scheduled as \(candidateName)"
                    )
                }
                index += 1
                continue
            }

            claimedDestinations[candidatePath] = computedSourceHash ?? ""
            return DestinationResolution(
                destinationURL: candidateURL,
                action: .copyWithSuffix,
                matchedExistingSHA256: nil,
                note: "Destination name existed with different content; saving as \(candidateName)"
            )
        }

        // Fallback unreachable in practice
        let uuidName = ext.isEmpty ? "\(baseName)-\(UUID().uuidString.prefix(8))" : "\(baseName)-\(UUID().uuidString.prefix(8)).\(ext)"
        let fallbackURL = dirURL.appendingPathComponent(uuidName)
        claimedDestinations[fallbackURL.path] = computedSourceHash ?? ""
        return DestinationResolution(
            destinationURL: fallbackURL,
            action: .copyWithSuffix,
            matchedExistingSHA256: nil,
            note: "Renamed to \(uuidName) to avoid collision"
        )
    }

    public func computeTargetDirectory(
        destinationBase: String,
        fileURL: URL,
        sourceRootURL: URL,
        preserveRelativeSubpath: Bool
    ) -> URL {
        let baseURL = URL(fileURLWithPath: destinationBase, isDirectory: true).standardizedFileURL
        guard preserveRelativeSubpath else { return baseURL }

        let parentPath = fileURL.deletingLastPathComponent().standardizedFileURL.path
        let rootPath = sourceRootURL.standardizedFileURL.path
        guard parentPath.hasPrefix(rootPath), parentPath.count > rootPath.count else {
            return baseURL
        }
        var relative = String(parentPath.dropFirst(rootPath.count))
        while relative.hasPrefix("/") { relative.removeFirst() }
        guard !relative.isEmpty else { return baseURL }
        return baseURL.appendingPathComponent(relative, isDirectory: true)
    }

    public func collectSourceFiles(
        rootURL: URL,
        includeSubdirectories: Bool,
        skipHiddenFiles: Bool,
        scanErrors: inout [String]
    ) -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []

        if !includeSubdirectories {
            do {
                let items = try fm.contentsOfDirectory(
                    at: rootURL,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey],
                    options: skipHiddenFiles ? [.skipsHiddenFiles] : []
                )
                for url in items {
                    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    if values?.isRegularFile == true && values?.isSymbolicLink != true {
                        results.append(url.standardizedFileURL)
                    }
                }
            } catch {
                scanErrors.append("Failed to list \(rootURL.path): \(error.localizedDescription)")
            }
            return results.sorted { $0.path < $1.path }
        }

        let options: FileManager.DirectoryEnumerationOptions = skipHiddenFiles ? [.skipsHiddenFiles] : []
        var collectedErrors: [String] = []
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey],
            options: options,
            errorHandler: { url, error in
                collectedErrors.append("Access error at \(url.path): \(error.localizedDescription)")
                return true
            }
        ) else {
            scanErrors.append("Unable to enumerate \(rootURL.path)")
            return []
        }

        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if values?.isRegularFile == true {
                results.append(fileURL.standardizedFileURL)
            }
        }
        scanErrors.append(contentsOf: collectedErrors)

        return results.sorted { $0.path < $1.path }
    }

    /// Generates practical starter classification rules matching common categories (Pictures, Movies, Installers, Documents, Archives).
    public static func starterRules(destinationRoot: String, sourceFolderPath: String? = nil) -> [ArchiveRule] {
        let base = URL(fileURLWithPath: destinationRoot, isDirectory: true).standardizedFileURL
        return [
            ArchiveRule(
                name: "Pictures & Images",
                fileCategories: [.images],
                sourceFolderPath: sourceFolderPath,
                destinationFolderPath: base.appendingPathComponent("Pictures").path
            ),
            ArchiveRule(
                name: "Movies & Videos",
                fileCategories: [.videos],
                sourceFolderPath: sourceFolderPath,
                destinationFolderPath: base.appendingPathComponent("Movies").path
            ),
            ArchiveRule(
                name: "Installers & Disk Images",
                fileCategories: [.installers],
                sourceFolderPath: sourceFolderPath,
                destinationFolderPath: base.appendingPathComponent("Installers").path
            ),
            ArchiveRule(
                name: "Documents & PDFs",
                fileCategories: [.documents],
                sourceFolderPath: sourceFolderPath,
                destinationFolderPath: base.appendingPathComponent("Documents").path
            ),
            ArchiveRule(
                name: "Compressed Archives",
                fileCategories: [.archives],
                sourceFolderPath: sourceFolderPath,
                destinationFolderPath: base.appendingPathComponent("Archives").path
            )
        ]
    }
}
