import Foundation
import XCTest
@testable import DiskStewardCore

private struct MockVolumeProvider: VolumeProvider, @unchecked Sendable {
    var volumes: [DiskVolume]
    func mountedVolumes(at date: Date) -> [DiskVolume] {
        volumes.map { vol in
            var copy = vol
            copy.lastUpdated = date
            return copy
        }
    }
}

final class VolumeMonitorTests: XCTestCase {
    func testTracksMainAndAdditionalDisksAndHandlesDisconnectWithoutStaleMetrics() {
        let main = DiskVolume(
            id: "uuid-main",
            name: "Macintosh HD",
            mountPath: "/",
            uuid: "uuid-main",
            isMainDisk: true,
            isInternal: true,
            isRemovable: false,
            isConnected: true,
            totalBytes: 1_000_000_000_000,
            freeBytes: 250_000_000_000
        )
        let storage0 = DiskVolume(
            id: "uuid-storage0",
            name: "Storage0",
            mountPath: "/Volumes/Storage0",
            uuid: "uuid-storage0",
            isMainDisk: false,
            isInternal: false,
            isRemovable: false,
            isConnected: true,
            totalBytes: 4_000_000_000_000,
            freeBytes: 1_500_000_000_000
        )

        var mounted = [main, storage0]
        final class DynamicProvider: VolumeProvider, @unchecked Sendable {
            var list: () -> [DiskVolume]
            init(list: @escaping () -> [DiskVolume]) { self.list = list }
            func mountedVolumes(at date: Date) -> [DiskVolume] {
                list().map {
                    var v = $0
                    v.lastUpdated = date
                    return v
                }
            }
        }

        let monitor = VolumeMonitor(provider: DynamicProvider { mounted })
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let first = monitor.refresh(at: t1)
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(first[0].mountPath, "/")
        XCTAssertEqual(first[0].usedBytes, 750_000_000_000)
        XCTAssertTrue(first[1].isConnected)
        XCTAssertEqual(first[1].freeBytes, 1_500_000_000_000)

        // Disconnect Storage0 -> must remain visible as Unavailable with zeroed live measurements (plan I-2).
        mounted = [main]
        let t2 = t1.addingTimeInterval(60)
        let second = monitor.refresh(at: t2)
        XCTAssertEqual(second.count, 2)
        let offline = second.first { $0.mountPath == "/Volumes/Storage0" }
        XCTAssertNotNil(offline)
        XCTAssertEqual(offline?.isConnected, false)
        XCTAssertEqual(offline?.statusLabel, "Unavailable")
        XCTAssertEqual(offline?.totalBytes, 0)
        XCTAssertEqual(offline?.freeBytes, 0)
        XCTAssertEqual(offline?.usedBytes, 0)
        XCTAssertEqual(offline?.lastUpdated, t1)

        // Reconnect Storage0 with updated free space -> refreshes live metrics.
        let updatedStorage0 = DiskVolume(
            id: "uuid-storage0",
            name: "Storage0",
            mountPath: "/Volumes/Storage0",
            uuid: "uuid-storage0",
            isMainDisk: false,
            isInternal: false,
            isRemovable: false,
            isConnected: true,
            totalBytes: 4_000_000_000_000,
            freeBytes: 1_200_000_000_000
        )
        mounted = [main, updatedStorage0]
        let t3 = t2.addingTimeInterval(60)
        let third = monitor.refresh(at: t3)
        let reconnected = third.first { $0.mountPath == "/Volumes/Storage0" }
        XCTAssertEqual(reconnected?.isConnected, true)
        XCTAssertEqual(reconnected?.freeBytes, 1_200_000_000_000)
        XCTAssertEqual(reconnected?.usedBytes, 2_800_000_000_000)
        XCTAssertEqual(reconnected?.lastUpdated, t3)
    }

    func testVolumeRootResolutionAndAvailability() {
        XCTAssertEqual(VolumeMonitor.volumeRootPath(forDestination: "/Volumes/Storage0/Pictures/2026"), "/Volumes/Storage0")
        XCTAssertEqual(VolumeMonitor.volumeRootPath(forDestination: "/Volumes/Storage1"), "/Volumes/Storage1")
        XCTAssertEqual(VolumeMonitor.volumeRootPath(forDestination: "/Users/boris/Archive"), "/")

        let mounted: Set<String> = ["/", "/Volumes/Storage0"]
        XCTAssertTrue(VolumeMonitor.isDestinationVolumeAvailable("/Volumes/Storage0/Pictures", mountedVolumePaths: mounted))
        XCTAssertFalse(VolumeMonitor.isDestinationVolumeAvailable("/Volumes/Storage1/Movies", mountedVolumePaths: mounted))
        XCTAssertTrue(VolumeMonitor.isDestinationVolumeAvailable("/Users/boris/Archive", mountedVolumePaths: mounted))
    }

    func testSystemVolumeProviderDetectsMainDiskAndVersionIsReadable() {
        let provider = SystemVolumeProvider()
        let volumes = provider.mountedVolumes(at: Date())
        let main = volumes.first { $0.isMainDisk }
        XCTAssertNotNil(main, "SystemVolumeProvider must detect the main macOS volume '/'")
        XCTAssertEqual(main?.mountPath, "/")
        XCTAssertEqual(main?.isConnected, true)
        XCTAssertGreaterThan(main?.totalBytes ?? 0, 0)
        XCTAssertGreaterThan(main?.freeBytes ?? 0, 0)
        XCTAssertGreaterThan(main?.usedBytes ?? 0, 0)
        XCTAssertFalse(DiskStewardVersion.current.isEmpty)
    }
}
