import Foundation

/// Evaluates user-defined folder cleanup rules (by file type, custom extensions, filename pattern, age, and size)
/// in read-only mode to produce reviewable CleanupCandidates requiring user confirmation before deletion (DEC-011, DEC-003).
public struct CleanupRuleEngine: Sendable {
    private static let blockedTargetRoots: Set<String> = [
        "/",
        "/System",
        "/Library",
        "/Applications",
        "/usr",
        "/bin",
        "/sbin",
        "/dev",
        "/etc",
        "/var",
        "/Volumes"
    ]

    public init() {}

    /// Evaluates a single CleanupRule recursively (or top-level only) and returns matching candidates sorted largest first.
    public func evaluate(rule: CleanupRule, now: Date = Date()) -> (candidates: [CleanupCandidate], notes: [String]) {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: rule.folderPath).standardizedFileURL
        let rootPath = rootURL.path

        guard !rootPath.isEmpty else {
            return ([], ["Choose a target folder for rule '\(rule.name)'."])
        }
        if Self.blockedTargetRoots.contains(rootPath) {
            return ([], ["Refused to run folder cleanup rule directly on protected system root '\(rootPath)'."])
        }
        guard rule.hasCriteria else {
            return ([], ["Rule '\(rule.name)' needs at least one filter (file type, extension, filename pattern, age, or minimum size)."])
        }
        guard fm.fileExists(atPath: rootPath) else {
            return ([], ["Target folder does not exist: \(rootPath)"])
        }

        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .isVolumeKey,
            .fileSizeKey,
            .totalFileAllocatedSizeKey,
            .contentModificationDateKey
        ]

        var matched: [CleanupCandidate] = []
        var notes: [String] = []

        if !rule.includeSubdirectories {
            do {
                let items = try fm.contentsOfDirectory(
                    at: rootURL,
                    includingPropertiesForKeys: keys,
                    options: rule.skipHiddenFiles ? [.skipsHiddenFiles] : []
                )
                for fileURL in items {
                    if let candidate = evaluateFile(url: fileURL, rule: rule, keys: Set(keys), now: now) {
                        matched.append(candidate)
                    }
                }
            } catch {
                notes.append("Could not read \(rootPath): \(error.localizedDescription)")
            }
        } else {
            var enumErrors: [String] = []
            let options: FileManager.DirectoryEnumerationOptions = rule.skipHiddenFiles ? [.skipsHiddenFiles] : []
            guard let enumerator = fm.enumerator(
                at: rootURL,
                includingPropertiesForKeys: keys,
                options: options,
                errorHandler: { url, error in
                    enumErrors.append("Access error at \(url.path): \(error.localizedDescription)")
                    return true
                }
            ) else {
                return ([], ["Unable to enumerate \(rootPath)"])
            }

            let keySet = Set(keys)
            for case let itemURL as URL in enumerator {
                let itemPath = itemURL.path
                if StorageScanner.shouldSkipVirtualPath(itemPath, rootPath: rootPath) {
                    enumerator.skipDescendants()
                    continue
                }
                guard let values = try? itemURL.resourceValues(forKeys: keySet) else { continue }
                if values.isSymbolicLink == true || values.isVolume == true {
                    enumerator.skipDescendants()
                    continue
                }
                // Never descend inside .git internal object storage when cleaning a folder.
                if values.isDirectory == true && itemURL.lastPathComponent == ".git" {
                    enumerator.skipDescendants()
                    continue
                }
                if values.isRegularFile == true {
                    if let candidate = evaluateFile(url: itemURL, values: values, rule: rule, now: now) {
                        matched.append(candidate)
                    }
                }
            }
            if !enumErrors.isEmpty {
                notes.append("\(enumErrors.count) inaccessible item(s) skipped while evaluating '\(rule.name)'.")
            }
        }

        matched.sort { lhs, rhs in
            if lhs.estimatedReclaimableBytes != rhs.estimatedReclaimableBytes {
                return lhs.estimatedReclaimableBytes > rhs.estimatedReclaimableBytes
            }
            return lhs.location < rhs.location
        }
        return (matched, notes)
    }

    /// Evaluates a single rule and wraps it directly into a ready-to-confirm CleanupProposal.
    public func buildProposal(for rule: CleanupRule, now: Date = Date()) -> CleanupProposal {
        let (candidates, notes) = evaluate(rule: rule, now: now)
        return CleanupProposal(createdAt: now, candidates: candidates, notes: notes)
    }

    private func evaluateFile(
        url: URL,
        rule: CleanupRule,
        keys: Set<URLResourceKey>,
        now: Date
    ) -> CleanupCandidate? {
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isRegularFile == true,
              values.isSymbolicLink != true else {
            return nil
        }
        return evaluateFile(url: url, values: values, rule: rule, now: now)
    }

    private func evaluateFile(
        url: URL,
        values: URLResourceValues,
        rule: CleanupRule,
        now: Date
    ) -> CleanupCandidate? {
        let fileName = url.lastPathComponent
        let stdPath = url.standardizedFileURL.path
        let ext = (fileName as NSString).pathExtension.lowercased()
        let category = FileCategory.classify(fileName: fileName, path: stdPath, isDirectory: false)

        // 1. File type / custom extension condition (OR between selected categories and custom extensions)
        let hasTypeCondition = !rule.fileCategories.isEmpty || !rule.customExtensions.isEmpty
        if hasTypeCondition {
            let matchesCategory = rule.fileCategories.contains(category)
            let matchesExt = !ext.isEmpty && rule.customExtensions.contains(ext)
            if !matchesCategory && !matchesExt { return nil }
        }

        // 2. Filename pattern condition
        let trimmedPattern = rule.fileNamePattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if rule.fileNameMatchMode != .any && !trimmedPattern.isEmpty {
            let lowerName = fileName.lowercased()
            let lowerPattern = trimmedPattern.lowercased()
            switch rule.fileNameMatchMode {
            case .any:
                break
            case .contains:
                if !lowerName.contains(lowerPattern) { return nil }
            case .startsWith:
                if !lowerName.hasPrefix(lowerPattern) { return nil }
            case .endsWith:
                if !lowerName.hasSuffix(lowerPattern) { return nil }
            case .glob:
                if !ArchiveRuleEngine.matchesGlob(text: lowerName, pattern: lowerPattern) { return nil }
            }
        }

        let logicalSize = Int64(values.fileSize ?? 0)
        let allocated = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        let modDate = values.contentModificationDate ?? now

        // 3. Minimum size condition
        if rule.minimumSizeBytes > 0 && allocated < rule.minimumSizeBytes {
            return nil
        }

        // 4. Optional age condition
        if let olderDays = rule.olderThanDays {
            let ageDays = now.timeIntervalSince(modDate) / 86_400.0
            if ageDays < Double(olderDays) {
                return nil
            }
        }

        return CleanupCandidate(
            id: "rule:\(rule.id.uuidString):\(stdPath)",
            category: .ruleMatches,
            title: fileName,
            location: stdPath,
            estimatedReclaimableBytes: allocated,
            reason: "Matched rule '\(rule.name)' (\(rule.summaryDescription))",
            lastModified: modDate,
            isDirectory: false,
            snapshotFileSize: logicalSize,
            snapshotModifiedDate: modDate
        )
    }

    /// Quick-fill preset criteria for common folder cleanup tasks (ZIPs, Videos, Code, Installers, Logs).
    public static func presetRule(name: String, folderPath: String, categories: [FileCategory], extensions: [String] = []) -> CleanupRule {
        CleanupRule(
            name: name,
            folderPath: folderPath,
            includeSubdirectories: true,
            skipHiddenFiles: true,
            fileCategories: categories,
            customExtensions: extensions
        )
    }
}
