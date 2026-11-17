import Foundation

/// Opens zip archives (.xlsx, .pptx) with the system `unzip`, which macOS and Linux both ship.
public enum Unzip {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// Runs `unzip` and returns what it printed and its exit status
    /// (11 = entry not in the archive, 9 = not a zip file).
    static func run(_ args: [String]) throws -> (output: Data, status: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { throw Failure(description: error.localizedDescription) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        _ = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (data, p.terminationStatus)
    }

    /// Unpacks the whole archive into `dir`.
    public static func extract(_ zip: URL, to dir: URL) throws {
        let r = try run(["-qq", "-o", zip.path, "-d", dir.path])
        if r.status == 9 { throw Failure(description: "\(zip.lastPathComponent) is not a valid file (not a zip archive)") }
        guard r.status <= 1 else { throw Failure(description: "unzip exit \(r.status)") }
    }
}
