import Foundation

/// Formats byte sizes consistently using standard macOS decimal file units (KB, MB, GB, TB).
public enum ByteFormatting {
    public static func string(from bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: max(0, bytes))
    }

    public static func percentString(_ fraction: Double) -> String {
        let clamped = min(max(fraction, 0), 1)
        return String(format: "%.1f%%", clamped * 100)
    }
}

/// Represents a monitored local or external storage volume.
public struct DiskVolume: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var mountPath: String
    public var uuid: String?
    public var isMainDisk: Bool
    public var isInternal: Bool
    public var isRemovable: Bool
    public var isConnected: Bool
    public var totalBytes: Int64
    public var freeBytes: Int64
    public var purgeableBytes: Int64
    public var lastUpdated: Date

    public init(
        id: String,
        name: String,
        mountPath: String,
        uuid: String? = nil,
        isMainDisk: Bool,
        isInternal: Bool,
        isRemovable: Bool,
        isConnected: Bool,
        totalBytes: Int64,
        freeBytes: Int64,
        purgeableBytes: Int64 = 0,
        lastUpdated: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.mountPath = mountPath
        self.uuid = uuid
        self.isMainDisk = isMainDisk
        self.isInternal = isInternal
        self.isRemovable = isRemovable
        self.isConnected = isConnected
        self.totalBytes = max(0, totalBytes)
        self.freeBytes = max(0, freeBytes)
        self.purgeableBytes = max(0, purgeableBytes)
        self.lastUpdated = lastUpdated
    }

    public var usedBytes: Int64 {
        guard isConnected else { return 0 }
        return max(0, totalBytes - freeBytes)
    }

    public var usedFraction: Double {
        guard isConnected, totalBytes > 0 else { return 0 }
        return min(max(Double(usedBytes) / Double(totalBytes), 0), 1)
    }

    public var freeFraction: Double {
        guard isConnected, totalBytes > 0 else { return 0 }
        return min(max(Double(freeBytes) / Double(totalBytes), 0), 1)
    }

    public var statusLabel: String {
        isConnected ? "Connected" : "Unavailable"
    }

    public var kindLabel: String {
        if isMainDisk { return "Main Disk" }
        if isRemovable { return "Removable Disk" }
        return isInternal ? "Internal Volume" : "External Storage"
    }
}
