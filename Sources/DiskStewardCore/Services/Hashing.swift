import CryptoKit
import Darwin
import Foundation

/// Zero-ObjC-allocation streaming SHA-256 hasher using POSIX open/read/close and a fixed reusable buffer.
/// Guarantees constant ~1 MB memory footprint regardless of how many gigabytes or files are hashed (DEC-007).
public enum FileHasher {
    public static func sha256(of url: URL, chunkSize: Int = 1_048_576) throws -> String {
        let fd = url.withUnsafeFileSystemRepresentation { pathPtr -> Int32 in
            guard let pathPtr else { return -1 }
            return Darwin.open(pathPtr, O_RDONLY)
        }
        guard fd >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))]
            )
        }
        defer { Darwin.close(fd) }

        // Hint sequential read access to avoid bloating the macOS unified buffer cache during bulk archiving.
        _ = Darwin.fcntl(fd, F_NOCACHE, 1)

        var buffer = [UInt8](repeating: 0, count: max(4096, chunkSize))
        var hasher = SHA256()

        while true {
            let bytesRead: Int = buffer.withUnsafeMutableBytes { rawBuf in
                guard let base = rawBuf.baseAddress else { return 0 }
                return Darwin.read(fd, base, rawBuf.count)
            }
            if bytesRead > 0 {
                buffer.withUnsafeBytes { rawBuf in
                    let slice = UnsafeRawBufferPointer(rebasing: rawBuf.prefix(bytesRead))
                    hasher.update(bufferPointer: slice)
                }
            } else if bytesRead == 0 {
                break
            } else {
                if errno == EINTR { continue }
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errno),
                    userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))]
                )
            }
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
