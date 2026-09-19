import Foundation

/// Build alongside the destination, replacing it only after successful export.
enum ExportDestination {
    static func write(to destination: URL, produce: (URL) throws -> Void) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".export-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try produce(temporary)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }
}
