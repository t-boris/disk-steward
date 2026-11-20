import Foundation

/// Output captured from an external CLI invocation.
public struct CommandOutput: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Injectable external command runner for deterministic testing of Docker discovery and cleanup.
public protocol CommandRunner: Sendable {
    func findExecutable(named name: String) -> String?
    func run(executablePath: String, arguments: [String]) async throws -> CommandOutput
}

/// Default macOS Process-based CommandRunner that drains stdout/stderr concurrently to avoid pipe deadlocks.
public struct ProcessCommandRunner: CommandRunner {
    private static let searchPaths = [
        "/usr/local/bin",
        "/opt/homebrew/bin",
        "/usr/bin",
        "/bin",
        "/Applications/Docker.app/Contents/Resources/bin"
    ]

    public init() {}

    public func findExecutable(named name: String) -> String? {
        let fm = FileManager.default
        for dir in Self.searchPaths {
            let full = (dir as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: full) {
                return full
            }
        }
        return nil
    }

    public func run(executablePath: String, arguments: [String]) async throws -> CommandOutput {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let group = DispatchGroup()
                nonisolated(unsafe) var outData = Data()
                nonisolated(unsafe) var errData = Data()

                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }

                process.waitUntilExit()
                group.wait()

                let stdout = String(data: outData, encoding: .utf8) ?? ""
                let stderr = String(data: errData, encoding: .utf8) ?? ""
                continuation.resume(
                    returning: CommandOutput(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
                )
            }
        }
    }
}

/// Result of inspecting Docker artifacts for cleanup opportunities.
public struct DockerInspectionResult: Sendable {
    public let isAvailable: Bool
    public let statusMessage: String
    public let candidates: [CleanupCandidate]

    public init(isAvailable: Bool, statusMessage: String, candidates: [CleanupCandidate]) {
        self.isAvailable = isAvailable
        self.statusMessage = statusMessage
        self.candidates = candidates
    }
}

/// Inspects Docker images, stopped containers, dangling volumes, and build cache (read-only),
/// and executes targeted removal via Docker CLI ONLY after user confirmation (REQ-006, DEC-006).
public struct DockerInspector: Sendable {
    private let runner: CommandRunner

    public init(runner: CommandRunner = ProcessCommandRunner()) {
        self.runner = runner
    }

    /// Read-only discovery of reclaimable Docker artifacts.
    public func discoverArtifacts() async -> DockerInspectionResult {
        guard let dockerPath = runner.findExecutable(named: "docker") else {
            return DockerInspectionResult(
                isAvailable: false,
                statusMessage: "Docker CLI is not installed on this Mac.",
                candidates: []
            )
        }

        // Verify daemon connectivity cleanly.
        do {
            let info = try await runner.run(executablePath: dockerPath, arguments: ["info", "--format", "{{.ServerVersion}}"])
            if info.exitCode != 0 {
                let errSummary = info.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return DockerInspectionResult(
                    isAvailable: false,
                    statusMessage: errSummary.isEmpty
                        ? "Docker daemon is not running. Start Docker Desktop to inspect Docker artifacts."
                        : "Docker daemon unavailable: \(errSummary)",
                    candidates: []
                )
            }
        } catch {
            return DockerInspectionResult(
                isAvailable: false,
                statusMessage: "Could not contact Docker: \(error.localizedDescription)",
                candidates: []
            )
        }

        var candidates: [CleanupCandidate] = []
        var usedImageTokens: Set<String> = []

        // 1. Inspect all containers to identify stopped containers AND images currently in use.
        if let psOut = try? await runner.run(
            executablePath: dockerPath,
            arguments: ["ps", "-a", "--no-trunc", "--size", "--format", "{{json .}}"]
        ), psOut.exitCode == 0 {
            for line in psOut.stdout.split(separator: "\n") {
                guard let dict = parseJSONLine(String(line)) else { continue }
                let imageRef = dict["Image"] ?? ""
                if !imageRef.isEmpty { usedImageTokens.insert(imageRef) }
                let state = (dict["State"] ?? dict["Status"] ?? "").lowercased()
                let isStopped = state.hasPrefix("exited") || state.hasPrefix("dead") || state.hasPrefix("created")
                if isStopped, let id = dict["ID"], !id.isEmpty {
                    let shortID = String(id.prefix(12))
                    let name = dict["Names"] ?? shortID
                    let sizeStr = dict["Size"] ?? "0B"
                    let bytes = Self.parseDockerSize(sizeStr)
                    candidates.append(
                        CleanupCandidate(
                            id: "docker:container:\(id)",
                            category: .dockerArtifacts,
                            title: "Stopped container: \(name)",
                            location: "docker://container/\(shortID) (\(imageRef))",
                            estimatedReclaimableBytes: bytes,
                            reason: "Container is stopped (\(dict["Status"] ?? state))",
                            dockerArtifactKind: .stoppedContainer,
                            dockerObjectID: id
                        )
                    )
                }
            }
        }

        // 2. Inspect Docker images not referenced by any container.
        if let imgOut = try? await runner.run(
            executablePath: dockerPath,
            arguments: ["images", "--no-trunc", "--format", "{{json .}}"]
        ), imgOut.exitCode == 0 {
            var seenImageIDs: Set<String> = []
            for line in imgOut.stdout.split(separator: "\n") {
                guard let dict = parseJSONLine(String(line)), let id = dict["ID"], !id.isEmpty else { continue }
                guard !seenImageIDs.contains(id) else { continue }
                seenImageIDs.insert(id)

                let repo = dict["Repository"] ?? "<none>"
                let tag = dict["Tag"] ?? "<none>"
                let ref = (repo == "<none>" || tag == "<none>") ? id : "\(repo):\(tag)"
                let shortID = id.replacingOccurrences(of: "sha256:", with: "").prefix(12)

                let isInUse = usedImageTokens.contains(id)
                    || usedImageTokens.contains(String(shortID))
                    || usedImageTokens.contains(ref)
                    || usedImageTokens.contains(repo)
                if isInUse { continue }

                let bytes = Self.parseDockerSize(dict["Size"] ?? "0B")
                let label = (repo == "<none>") ? "Dangling image \(shortID)" : "Unused image: \(repo):\(tag)"
                candidates.append(
                    CleanupCandidate(
                        id: "docker:image:\(id)",
                        category: .dockerArtifacts,
                        title: label,
                        location: "docker://image/\(shortID)",
                        estimatedReclaimableBytes: bytes,
                        reason: repo == "<none>"
                            ? "Untagged dangling Docker image"
                            : "Image is not used by any existing container",
                        dockerArtifactKind: .unusedImage,
                        dockerObjectID: id
                    )
                )
            }
        }

        // 3. Inspect dangling volumes.
        if let volOut = try? await runner.run(
            executablePath: dockerPath,
            arguments: ["volume", "ls", "--filter", "dangling=true", "--format", "{{json .}}"]
        ), volOut.exitCode == 0 {
            for line in volOut.stdout.split(separator: "\n") {
                guard let dict = parseJSONLine(String(line)), let name = dict["Name"], !name.isEmpty else { continue }
                candidates.append(
                    CleanupCandidate(
                        id: "docker:volume:\(name)",
                        category: .dockerArtifacts,
                        title: "Dangling volume: \(name)",
                        location: "docker://volume/\(name)",
                        estimatedReclaimableBytes: 0,
                        reason: "Docker volume is not attached to any container",
                        dockerArtifactKind: .danglingVolume,
                        dockerObjectID: name
                    )
                )
            }
        }

        // 4. Inspect reclaimable Docker build cache via `docker system df`.
        if let dfOut = try? await runner.run(
            executablePath: dockerPath,
            arguments: ["system", "df", "--format", "{{json .}}"]
        ), dfOut.exitCode == 0 {
            for line in dfOut.stdout.split(separator: "\n") {
                guard let dict = parseJSONLine(String(line)) else { continue }
                let type = (dict["Type"] ?? "").lowercased()
                if type.contains("build cache") {
                    let reclaimable = Self.parseDockerSize(dict["Reclaimable"] ?? dict["Size"] ?? "0B")
                    if reclaimable > 0 {
                        candidates.append(
                            CleanupCandidate(
                                id: "docker:buildcache",
                                category: .dockerArtifacts,
                                title: "Docker Build Cache",
                                location: "docker://build-cache",
                                estimatedReclaimableBytes: reclaimable,
                                reason: "Cached Docker build layers reclaimable via `docker builder prune`",
                                dockerArtifactKind: .buildCache,
                                dockerObjectID: "build-cache"
                            )
                        )
                    }
                }
            }
        }

        candidates.sort { $0.estimatedReclaimableBytes > $1.estimatedReclaimableBytes }
        let msg = candidates.isEmpty
            ? "Docker is running; no reclaimable artifacts found."
            : "Docker is running; found \(candidates.count) reclaimable artifact(s)."
        return DockerInspectionResult(isAvailable: true, statusMessage: msg, candidates: candidates)
    }

    /// Executes user-confirmed removal of a single Docker artifact via Docker CLI (DEC-006).
    public func removeArtifact(_ candidate: CleanupCandidate) async -> CleanupItemResult {
        guard let dockerPath = runner.findExecutable(named: "docker") else {
            return CleanupItemResult(
                id: candidate.id,
                title: candidate.title,
                location: candidate.location,
                category: candidate.category,
                status: .failed,
                reclaimedBytes: 0,
                detail: "Docker CLI not found"
            )
        }

        guard let kind = candidate.dockerArtifactKind, let objectID = candidate.dockerObjectID else {
            return CleanupItemResult(
                id: candidate.id,
                title: candidate.title,
                location: candidate.location,
                category: candidate.category,
                status: .skippedRevalidationFailed,
                reclaimedBytes: 0,
                detail: "Missing Docker artifact metadata"
            )
        }

        let args: [String]
        switch kind {
        case .stoppedContainer:
            args = ["rm", objectID]
        case .unusedImage:
            args = ["rmi", objectID]
        case .danglingVolume:
            args = ["volume", "rm", objectID]
        case .buildCache:
            args = ["builder", "prune", "-f"]
        }

        do {
            let result = try await runner.run(executablePath: dockerPath, arguments: args)
            if result.exitCode == 0 {
                return CleanupItemResult(
                    id: candidate.id,
                    title: candidate.title,
                    location: candidate.location,
                    category: candidate.category,
                    status: .deletedViaDocker,
                    reclaimedBytes: candidate.estimatedReclaimableBytes,
                    detail: "Removed via `docker \(args.joined(separator: " "))`"
                )
            } else {
                let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return CleanupItemResult(
                    id: candidate.id,
                    title: candidate.title,
                    location: candidate.location,
                    category: candidate.category,
                    status: .failed,
                    reclaimedBytes: 0,
                    detail: err.isEmpty ? "Docker exited with code \(result.exitCode)" : err
                )
            }
        } catch {
            return CleanupItemResult(
                id: candidate.id,
                title: candidate.title,
                location: candidate.location,
                category: candidate.category,
                status: .failed,
                reclaimedBytes: 0,
                detail: error.localizedDescription
            )
        }
    }

    /// Parses Docker formatted byte strings such as "1.42GB", "350MB", "12.5kB (100%)", "24MB (virtual 1.2GB)".
    public static func parseDockerSize(_ raw: String) -> Int64 {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        // Take the first token before any parenthetical "(...)" such as "(85%)" or "(virtual 1.2GB)".
        let head = trimmed.split(separator: " ").first.map(String.init) ?? trimmed
        let pattern = #"^([0-9]+(?:\.[0-9]+)?)\s*([a-zA-Z]+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: head, range: NSRange(head.startIndex..., in: head)),
              let numRange = Range(match.range(at: 1), in: head),
              let unitRange = Range(match.range(at: 2), in: head),
              let value = Double(head[numRange]) else {
            return 0
        }

        let unit = head[unitRange].lowercased()
        let multiplier: Double
        switch unit {
        case "b": multiplier = 1
        case "kb", "kib": multiplier = 1_000
        case "mb", "mib": multiplier = 1_000_000
        case "gb", "gib": multiplier = 1_000_000_000
        case "tb", "tib": multiplier = 1_000_000_000_000
        default: multiplier = 1
        }
        return Int64((value * multiplier).rounded())
    }

    private func parseJSONLine(_ line: String) -> [String: String]? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var out: [String: String] = [:]
        for (k, v) in json {
            if let s = v as? String {
                out[k] = s
            } else {
                out[k] = "\(v)"
            }
        }
        return out
    }
}
