import OSLog

public enum SyncLog {
    private static let subsystem = "com.merlinkraemer.bounce"

    public static let discovery = Logger(subsystem: subsystem, category: "sync.discovery")
    public static let transport = Logger(subsystem: subsystem, category: "sync.transport")
    public static let sender = Logger(subsystem: subsystem, category: "sync.sender")
    public static let receiver = Logger(subsystem: subsystem, category: "sync.receiver")
    public static let apply = Logger(subsystem: subsystem, category: "sync.apply")
    public static let importer = Logger(subsystem: subsystem, category: "import")
    public static let player = Logger(subsystem: subsystem, category: "player")
    public static let notes = Logger(subsystem: subsystem, category: "notes")
}
