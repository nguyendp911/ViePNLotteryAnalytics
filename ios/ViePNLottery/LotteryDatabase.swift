import Foundation
import SQLite3

struct LotteryResult: Codable {
    let date: String
    let region: String
    let station: String
    let prize: String
    let position: Int
    let number: String
    let source: String
}
struct StationKey: Identifiable, Hashable {
    let region: String
    let station: String
    var id: String { region + ":" + station }
}
struct DataQuality {
    let resultCount: Int
    let drawCount: Int
    let earliest: String?
    let latest: String?
    let sourceCount: Int
}
enum LotteryDataError: LocalizedError {
    case database(String), invalidRow(Int), invalidFormat, invalidURL
    var errorDescription: String? {
        switch self {
        case .database(let text): return "Lỗi SQLite: " + text
        case .invalidRow(let index): return "Dữ liệu không hợp lệ ở dòng \(index)"
        case .invalidFormat: return "CSV hoặc JSON không hợp lệ"
        case .invalidURL: return "Địa chỉ HTTPS không hợp lệ"
        }
    }
}
final class LotteryDatabase {
    static let shared = try! LotteryDatabase()
    private var db: OpaquePointer?
    private init() throws {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard sqlite3_open(root.appendingPathComponent("lottery.sqlite").path, &db) == SQLITE_OK else {
            throw LotteryDataError.database("Không mở được CSDL")
        }
        try execute("CREATE TABLE IF NOT EXISTS results (date TEXT NOT NULL, region TEXT NOT NULL, station TEXT NOT NULL, prize TEXT NOT NULL, position INTEGER NOT NULL, number TEXT NOT NULL, source TEXT NOT NULL, PRIMARY KEY(date,region,station,prize,position));")
        try execute("CREATE INDEX IF NOT EXISTS idx_results_search ON results(region,station,date);")
    }
    deinit { sqlite3_close(db) }
    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let detail = error.map { String(cString: $0) } ?? "Query failed"
            sqlite3_free(error)
            throw LotteryDataError.database(detail)
        }
    }
    func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw LotteryDataError.database(String(cString: sqlite3_errmsg(db)))
        }
        return stmt
    }
    func bind(_ stmt: OpaquePointer?, _ values: [String]) {
        for (index,value) in values.enumerated() {
            _ = value.withCString {
                sqlite3_bind_text(stmt, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
        }
    }
    static func valid(_ r: LotteryResult) -> Bool {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        formatter.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")
        return r.date.count == 10 && formatter.date(from: r.date) != nil && r.date >= "2021-11-12"
            && ["MB","MT","MN"].contains(r.region) && !r.station.isEmpty && !r.prize.isEmpty
            && r.position > 0 && (2...6).contains(r.number.count) && !r.source.isEmpty
            && r.number.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
    }
    func importRows(_ records: [LotteryResult]) throws -> Int {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let stmt = try prepare("INSERT OR IGNORE INTO results(date,region,station,prize,position,number,source) VALUES(?,?,?,?,?,?,?);")
            defer { sqlite3_finalize(stmt) }
            var inserted = 0
            for (index, record) in records.enumerated() {
                guard Self.valid(record) else { throw LotteryDataError.invalidRow(index + 1) }
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                bind(stmt,[record.date,record.region,record.station,record.prize,String(record.position),record.number,record.source])
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw LotteryDataError.database(String(cString: sqlite3_errmsg(db)))
                }
                inserted += Int(sqlite3_changes(db))
            }
            try execute("COMMIT;")
            return inserted
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }
    func stations() throws -> [StationKey] {
        let stmt = try prepare("SELECT DISTINCT region,station FROM results ORDER BY region,station;")
        defer { sqlite3_finalize(stmt) }
        var results: [StationKey] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(StationKey(region: String(cString: sqlite3_column_text(stmt,0)), station: String(cString: sqlite3_column_text(stmt,1))))
        }
        return results
    }
    func frequencies(region: String, station: String, since: String, until: String) throws -> (sample: Int, counts: [Int]) {
        let stmt = try prepare("SELECT number FROM results WHERE region=? AND station=? AND date>=? AND date<=?;")
        defer { sqlite3_finalize(stmt) }
        bind(stmt,[region,station,since,until])
        var counts = Array(repeating: 0, count: 100)
        var sample = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            let value = String(cString: sqlite3_column_text(stmt,0))
            if let number = Int(value.suffix(2)) {
                counts[number] += 1
                sample += 1
            }
        }
        return (sample,counts)
    }
    func quality() throws -> DataQuality {
        let stmt = try prepare("SELECT COUNT(*),COUNT(DISTINCT date || '|' || region || '|' || station),MIN(date),MAX(date),COUNT(DISTINCT source) FROM results;")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw LotteryDataError.database("Không đọc được dữ liệu") }
        func text(_ column: Int32) -> String? { sqlite3_column_text(stmt,column).map { String(cString: $0) } }
        return DataQuality(resultCount: Int(sqlite3_column_int(stmt,0)), drawCount: Int(sqlite3_column_int(stmt,1)),
                           earliest:text(2),latest:text(3),sourceCount:Int(sqlite3_column_int(stmt,4)))
    }
}
