import Foundation

struct Version {
    static let major = 1
    static let minor = 0
    static let patch = 0

    /// 1.0.0.main.abc1234.42
    static var full: String {
        "\(major).\(minor).\(patch).\(branch).\(commitHash).\(buildNumber)"
    }

    /// 1.0.0
    static var short: String {
        "\(major).\(minor).\(patch)"
    }

    static let branch: String = {
        git("rev-parse", "--abbrev-ref", "HEAD") ?? "unknown"
    }()

    static let commitHash: String = {
        git("rev-parse", "--short=7", "HEAD") ?? "0000000"
    }()

    static let buildNumber: String = {
        git("rev-list", "--count", "HEAD") ?? "0"
    }()

    private static func git(_ args: String...) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = args
        // 프로젝트 루트에서 실행
        let source = URL(fileURLWithPath: #filePath)
        proc.currentDirectoryURL = source
            .deletingLastPathComponent() // iPlayer/
            .deletingLastPathComponent() // Sources/
            .deletingLastPathComponent() // project root
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}
