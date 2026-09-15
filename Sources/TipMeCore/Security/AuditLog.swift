import Foundation

/// One line in the audit log.
///
/// Every payment attempt writes at least two of these: one when the attempt is
/// authorised and one when it resolves. Identifiers are redacted — the log is
/// for reconstructing what the app did, not for building a record of who a user
/// tips.
public struct AuditEvent: Codable, Equatable, Sendable {
    public enum Stage: String, Codable, Sendable {
        case linkParsed
        case creatorResolved
        case quotePrepared
        case capsEvaluated
        case rateLimitEvaluated
        case authorizationRequested
        case authorizationGranted
        case authorizationDenied
        case tipPaymentAttempted
        case tipPaymentSucceeded
        case tipPaymentFailed
        case feePaymentAttempted
        case feePaymentSucceeded
        case feePaymentFailed
        case settled
    }

    public enum Outcome: String, Codable, Sendable {
        case ok
        case rejected
        case failed
    }

    public let timestamp: Date
    public let intentID: String
    public let stage: Stage
    public let outcome: Outcome
    public let platform: String?
    public let handle: String?
    public let destination: String?
    public let asset: String?
    public let tipMinorUnits: Int64?
    public let feeMinorUnits: Int64?
    public let fiatCurrency: String?
    public let fiatMinorUnits: Int64?
    public let paymentHash: String?
    public let detail: String?
    /// Which surface initiated it — the share extension or the host app.
    public let origin: String

    public init(timestamp: Date,
                intentID: String,
                stage: Stage,
                outcome: Outcome,
                origin: String,
                platform: String? = nil,
                handle: String? = nil,
                destination: String? = nil,
                asset: String? = nil,
                tipMinorUnits: Int64? = nil,
                feeMinorUnits: Int64? = nil,
                fiatCurrency: String? = nil,
                fiatMinorUnits: Int64? = nil,
                paymentHash: String? = nil,
                detail: String? = nil) {
        self.timestamp = timestamp
        self.intentID = intentID
        self.stage = stage
        self.outcome = outcome
        self.origin = origin
        self.platform = platform
        self.handle = handle
        self.destination = destination
        self.asset = asset
        self.tipMinorUnits = tipMinorUnits
        self.feeMinorUnits = feeMinorUnits
        self.fiatCurrency = fiatCurrency
        self.fiatMinorUnits = fiatMinorUnits
        self.paymentHash = paymentHash
        self.detail = detail
    }
}

public protocol AuditLog: Sendable {
    func append(_ event: AuditEvent) async
}

/// Append-only JSON-lines log.
///
/// One JSON object per line, which means a truncated write costs you the last
/// line and nothing else — a single JSON array would be unreadable after any
/// interrupted write, and this runs inside an app extension that the OS may
/// kill mid-payment.
public actor JSONLinesAuditLog: AuditLog {
    private let fileURL: URL
    private let maximumBytes: UInt64
    private let encoder: JSONEncoder

    public init(fileURL: URL, maximumBytes: UInt64 = 5 * 1024 * 1024) {
        self.fileURL = fileURL
        self.maximumBytes = maximumBytes
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
    }

    public func append(_ event: AuditEvent) async {
        guard var line = try? encoder.encode(event) else { return }
        line.append(0x0A) // newline

        let fm = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: directory.path) {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        rotateIfNeeded()

        if fm.fileExists(atPath: fileURL.path) {
            guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: fileURL, options: [.atomic])
            // Audit lines can name creators and amounts; keep them out of
            // reach of other processes and out of unencrypted backups.
            try? fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                  ofItemAtPath: fileURL.path)
        }
    }

    /// Single-generation rotation. Keeps the log bounded on a device where we
    /// cannot assume anyone will ever clean it up.
    private func rotateIfNeeded() {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? UInt64,
              size >= maximumBytes
        else { return }

        let rotated = fileURL.appendingPathExtension("1")
        try? fm.removeItem(at: rotated)
        try? fm.moveItem(at: fileURL, to: rotated)
    }

    public func readAll() -> [AuditEvent] {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8)
        else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { line in
            guard let lineData = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(AuditEvent.self, from: lineData)
        }
    }
}

public actor InMemoryAuditLog: AuditLog {
    public private(set) var events: [AuditEvent] = []
    public init() {}
    public func append(_ event: AuditEvent) async { events.append(event) }
    public func stages() -> [AuditEvent.Stage] { events.map(\.stage) }
}
