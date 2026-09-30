#!/usr/bin/env swift
// Measures whether the notification database is a fast enough arrival signal
// to replace the native banner entirely.
//
// The idea being tested: set an app's notification style to "None" so macOS
// never draws a banner, and present the notch card when the notification's
// record appears in Notification Center's database instead. This probe posts
// test notifications and reports, for each one, how long after macOS delivered
// it the record became readable — and, with --ax, how that compares with the
// native banner's first Accessibility event.
//
// It opens the database read-only and prints only record IDs, schema names and
// timings. It never reads or prints notification titles, bodies or payloads.
//
//   swiftc -O scripts/ncdb-probe.swift -o /tmp/ncdb-probe && /tmp/ncdb-probe --ax
//
// Options:
//   --count N      notifications to post (default 5)
//   --interval S   seconds between them (default 4)
//   --no-send      only watch; report records created by other apps
//   --ax           also time Notification Center's AXWindowCreated/AXLayoutChanged
//   --db PATH      database to open instead of the default locations
//
// The database is protected: the process running this needs Full Disk Access
// (System Settings > Privacy & Security > Full Disk Access; grant it to your
// terminal). --ax additionally needs Accessibility. Test notifications are
// posted through osascript, which macOS attributes to Script Editor, so set
// Script Editor's notification style to "None" to test the no-banner case.
// Quit NotchNotify first, otherwise --ax measures a banner it is also handling.

import AppKit
import ApplicationServices
import SQLite3

struct Options {
    var count = 5
    var interval: TimeInterval = 4
    var send = true
    var ax = false
    var dbPath: String?
}

func parseOptions() -> Options {
    var options = Options()
    var args = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = args.next() {
        switch arg {
        case "--count": options.count = args.next().flatMap(Int.init) ?? options.count
        case "--interval": options.interval = args.next().flatMap(TimeInterval.init) ?? options.interval
        case "--no-send": options.send = false
        case "--ax": options.ax = true
        case "--db": options.dbPath = args.next()
        default:
            FileHandle.standardError.write("unknown option \(arg)\n".data(using: .utf8)!)
            exit(2)
        }
    }
    return options
}

func candidatePaths(override: String?) -> [String] {
    if let override { return [override] }
    var paths = [NSHomeDirectory() + "/Library/Group Containers/group.com.apple.usernoted/db2/db"]
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    if confstr(_CS_DARWIN_USER_DIR, &buffer, buffer.count) > 0 {
        paths.append(String(cString: buffer) + "com.apple.notificationcenter/db2/db")
    }
    return paths
}

final class Database {
    let path: String
    private var handle: OpaquePointer?

    init?(path: String) {
        self.path = path
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              (try? query("SELECT count(*) FROM sqlite_master")) != nil else {
            sqlite3_close(handle)
            return nil
        }
    }

    deinit { sqlite3_close(handle) }

    var lastError: String { handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no handle" }

    func query(_ sql: String, _ bind: [Int64] = []) throws -> [[String: Any]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "sqlite", code: 1, userInfo: [NSLocalizedDescriptionKey: lastError])
        }
        defer { sqlite3_finalize(statement) }
        for (i, value) in bind.enumerated() { sqlite3_bind_int64(statement, Int32(i + 1), value) }
        var rows: [[String: Any]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: Any] = [:]
            for c in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, c))
                switch sqlite3_column_type(statement, c) {
                case SQLITE_INTEGER: row[name] = sqlite3_column_int64(statement, c)
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(statement, c)
                case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(statement, c))
                default: break
                }
            }
            rows.append(row)
        }
        return rows
    }

    func columns(of table: String) -> [String] {
        ((try? query("PRAGMA table_info(\(table))")) ?? []).compactMap { $0["name"] as? String }
    }
}

func now() -> TimeInterval { Date().timeIntervalSinceReferenceDate }

struct Arrival {
    let recID: Int64
    let isProbe: Bool
    let detectedAt: TimeInterval
    let deliveredAt: TimeInterval?
    let presented: Int64?
    let style: Int64?
}

final class Probe {
    private let options: Options
    private let db: Database
    private let recordColumns: Set<String>
    private let hasAppTable: Bool
    private var lastRecID: Int64
    private var sends: [(index: Int, at: TimeInterval)] = []
    private var axEvents: [(name: String, at: TimeInterval)] = []
    private var arrivals: [Arrival] = []
    private var sources: [DispatchSourceProtocol] = []
    private var axObserver: AXObserver?

    init(options: Options, db: Database) throws {
        self.options = options
        self.db = db
        recordColumns = Set(db.columns(of: "record"))
        hasAppTable = !db.columns(of: "app").isEmpty
        guard recordColumns.contains("rec_id") else {
            throw NSError(domain: "probe", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no record.rec_id column — schema changed"])
        }
        lastRecID = (try db.query("SELECT max(rec_id) AS m FROM record").first?["m"] as? Int64) ?? 0
    }

    func printSchema() {
        let tables = ((try? db.query("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")) ?? [])
            .compactMap { $0["name"] as? String }
        print("database: \(db.path)")
        print("tables: \(tables.joined(separator: ", "))")
        print("record columns: \(recordColumns.sorted().joined(separator: ", "))")
        print("starting after rec_id \(lastRecID)")
    }

    func start() {
        watchFiles()
        let poll = DispatchSource.makeTimerSource(queue: .main)
        poll.schedule(deadline: .now(), repeating: .milliseconds(5))
        poll.setEventHandler { [weak self] in self?.check() }
        poll.resume()
        sources.append(poll)
        if options.ax { startAX() }
        if options.send {
            for i in 0..<options.count {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1 + Double(i) * options.interval) { [weak self] in
                    self?.send(index: i + 1)
                }
            }
            let end = 1 + Double(options.count) * options.interval + 1
            DispatchQueue.main.asyncAfter(deadline: .now() + end) { [weak self] in
                self?.summarize()
                exit(0)
            }
        } else {
            print("watching — Ctrl-C to stop")
            signal(SIGINT, SIG_IGN)
            let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            sigint.setEventHandler { [weak self] in
                self?.summarize()
                exit(0)
            }
            sigint.resume()
            sources.append(sigint)
        }
    }

    private func watchFiles() {
        for suffix in ["", "-wal"] {
            let fd = open(db.path + suffix, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                                   eventMask: [.write, .extend], queue: .main)
            source.setEventHandler { [weak self] in self?.check() }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources.append(source)
        }
    }

    private func startAX() {
        guard AXIsProcessTrusted() else {
            print("--ax skipped: this process has no Accessibility permission")
            return
        }
        guard let pid = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first?.processIdentifier
        else {
            print("--ax skipped: Notification Center is not running")
            return
        }
        var observer: AXObserver?
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverCreate(pid, { _, _, name, refcon in
            guard let refcon else { return }
            Unmanaged<Probe>.fromOpaque(refcon).takeUnretainedValue().axEvent(name as String)
        }, &observer) == .success, let observer else { return }
        let app = AXUIElementCreateApplication(pid)
        for name in [kAXWindowCreatedNotification, kAXLayoutChangedNotification] {
            AXObserverAddNotification(observer, app, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        axObserver = observer
    }

    fileprivate func axEvent(_ name: String) {
        axEvents.append((name, now()))
    }

    private func send(index: Int) {
        sends.append((index, now()))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "display notification \"NotchNotify database probe\" with title \"Probe \(index)\""]
        try? process.run()
    }

    private func check() {
        var select = ["r.rec_id AS rec_id"]
        for column in ["delivered_date", "presented", "style"] where recordColumns.contains(column) {
            select.append("r.\(column) AS \(column)")
        }
        var sql = "SELECT \(select.joined(separator: ", "))"
        if hasAppTable, recordColumns.contains("app_id") {
            sql += ", a.identifier AS identifier FROM record r LEFT JOIN app a ON a.app_id = r.app_id"
        } else {
            sql += " FROM record r"
        }
        sql += " WHERE r.rec_id > ? ORDER BY r.rec_id"
        guard let rows = try? db.query(sql, [lastRecID]), !rows.isEmpty else { return }
        let detectedAt = now()
        for row in rows {
            guard let recID = row["rec_id"] as? Int64 else { continue }
            lastRecID = max(lastRecID, recID)
            let identifier = row["identifier"] as? String ?? ""
            let arrival = Arrival(recID: recID, isProbe: identifier.contains("ScriptEditor"),
                                  detectedAt: detectedAt, deliveredAt: row["delivered_date"] as? Double,
                                  presented: row["presented"] as? Int64, style: row["style"] as? Int64)
            arrivals.append(arrival)
            report(arrival)
        }
    }

    private func report(_ arrival: Arrival) {
        var parts = ["rec_id=\(arrival.recID)", arrival.isProbe ? "probe" : "other-app"]
        if let delivered = arrival.deliveredAt {
            parts.append(ms("after delivered_date", arrival.detectedAt - delivered))
        }
        if let send = sends.last(where: { $0.at <= arrival.detectedAt }) {
            parts.append(ms("after send #\(send.index)", arrival.detectedAt - send.at))
            if let ax = axEvents.first(where: { $0.at >= send.at }) {
                parts.append(ms("vs first \(ax.name)", arrival.detectedAt - ax.at))
            } else if options.ax {
                parts.append("no AX event yet")
            }
        }
        if let presented = arrival.presented { parts.append("presented=\(presented)") }
        if let style = arrival.style { parts.append("style=\(style)") }
        print(parts.joined(separator: "  "))
    }

    private func summarize() {
        print("\n── summary ──")
        let probes = arrivals.filter(\.isProbe)
        print("records seen: \(arrivals.count) (\(probes.count) from this probe, \(sends.count) sent)")
        let afterDelivery = probes.compactMap { a in a.deliveredAt.map { a.detectedAt - $0 } }
        printStats("detected after delivered_date", afterDelivery)
        if options.ax {
            let vsAX = probes.compactMap { a -> TimeInterval? in
                guard let send = sends.last(where: { $0.at <= a.detectedAt }),
                      let ax = axEvents.first(where: { $0.at >= send.at }) else { return nil }
                return a.detectedAt - ax.at
            }
            printStats("detected relative to first AX event (negative = before the banner)", vsAX)
            let withoutBanner = sends.filter { send in
                let next = sends.first(where: { $0.at > send.at })?.at ?? .infinity
                return !axEvents.contains { $0.at >= send.at && $0.at < next }
            }
            print("sends with no Notification Center AX event: \(withoutBanner.count) of \(sends.count)")
        }
    }

    private func printStats(_ label: String, _ values: [TimeInterval]) {
        guard !values.isEmpty else {
            print("\(label): no samples")
            return
        }
        let sorted = values.sorted()
        let median = sorted[sorted.count / 2]
        print(String(format: "%@: median %.1f ms, min %.1f ms, max %.1f ms (n=%d)",
                     label, median * 1000, sorted.first! * 1000, sorted.last! * 1000, sorted.count))
    }

    private func ms(_ label: String, _ interval: TimeInterval) -> String {
        String(format: "%@ %.1fms", label, interval * 1000)
    }
}

let options = parseOptions()
let paths = candidatePaths(override: options.dbPath)
guard let db = paths.lazy.compactMap(Database.init(path:)).first else {
    print("could not open the notification database read-only. Tried:")
    for path in paths {
        let exists = FileManager.default.fileExists(atPath: path)
        print("  \(path)\(exists ? "" : " (not found)")")
    }
    print("If the first path exists, grant Full Disk Access to the app running this probe.")
    exit(1)
}

do {
    let probe = try Probe(options: options, db: db)
    probe.printSchema()
    probe.start()
    withExtendedLifetime(probe) { CFRunLoopRun() }
} catch {
    print("probe failed: \(error.localizedDescription)")
    exit(1)
}
