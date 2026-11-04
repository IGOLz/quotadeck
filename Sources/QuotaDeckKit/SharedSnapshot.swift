import Foundation

/// What the app hands to the WidgetKit extension: the latest account usage,
/// written as JSON to a file the sandboxed extension may read. No tokens.
public struct WidgetSnapshot: Codable, Sendable {
    public var accounts: [Account]
    public var writtenAt: Date

    public init(accounts: [Account], writtenAt: Date = Date()) {
        self.accounts = accounts
        self.writtenAt = writtenAt
    }
}

public enum SharedSnapshot {
    /// WidgetKit kind of the all-accounts widget.
    public static let widgetKind = "QuotaDeckWidget"
    /// WidgetKit kind of the small, one-account widget (account chosen in Edit Widget).
    public static let accountWidgetKind = "QuotaDeckAccountWidget"

    /// `~/Library/Application Support/QuotaDeck/widget-snapshot.json`, resolved from the
    /// real home directory: inside the extension's sandbox `NSHomeDirectory()` points at
    /// its container. The extension's entitlements grant read-only access to this folder.
    public static let url: URL = {
        let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } }
            ?? NSHomeDirectory()
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/QuotaDeck", isDirectory: true)
            .appendingPathComponent("widget-snapshot.json")
    }()

    public static func write(_ snapshot: WidgetSnapshot) throws {
        // Owner-only: the snapshot holds account emails.
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        try enc.encode(snapshot).write(to: url, options: .atomic)
    }

    public static func read() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return try? dec.decode(WidgetSnapshot.self, from: data)
    }
}
