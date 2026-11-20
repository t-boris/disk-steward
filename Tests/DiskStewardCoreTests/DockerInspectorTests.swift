import Foundation
import XCTest
@testable import DiskStewardCore

final class DockerInspectorTests: XCTestCase {
    func testParsesDockerSizeStrings() {
        XCTAssertEqual(DockerInspector.parseDockerSize("0B"), 0)
        XCTAssertEqual(DockerInspector.parseDockerSize("512B"), 512)
        XCTAssertEqual(DockerInspector.parseDockerSize("12.5kB"), 12_500)
        XCTAssertEqual(DockerInspector.parseDockerSize("350MB"), 350_000_000)
        XCTAssertEqual(DockerInspector.parseDockerSize("1.42GB (85%)"), 1_420_000_000)
        XCTAssertEqual(DockerInspector.parseDockerSize("24MB (virtual 1.2GB)"), 24_000_000)
    }

    func testReportsGracefullyWhenDockerUnavailable() async {
        struct MissingRunner: CommandRunner {
            func findExecutable(named name: String) -> String? { nil }
            func run(executablePath: String, arguments: [String]) async throws -> CommandOutput {
                CommandOutput(exitCode: 127, stdout: "", stderr: "missing")
            }
        }

        let inspector = DockerInspector(runner: MissingRunner())
        let result = await inspector.discoverArtifacts()
        XCTAssertFalse(result.isAvailable)
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertTrue(result.statusMessage.lowercased().contains("not installed"))
    }
}
