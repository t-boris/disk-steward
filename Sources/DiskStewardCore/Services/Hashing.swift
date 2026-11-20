import CryptoKit
import Foundation

/// Streaming cryptographic hashing utilities for byte-for-byte archive verification (DEC-007).
public enum FileHasher {
    /// Computes the lowercase hexadecimal SHA-256 digest of a file using fixed-size streaming chunks.
    public static func sha256(of url: URL, chunkSize: Int = 1_048_576) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk: Data
            do {
                guard let data = try handle.read(upToCount: chunkSize), !data.isEmpty else {
                    break
                }
                chunk = data
            } catch {
                throw error
            }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
