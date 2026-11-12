import Foundation
import SQLite3

/// Historical importer using publicly published quarterly SQLite archives.
/// A quarter is marked complete only after successful verification and import.
extension LotteryDatabase {
    func importedQuarter(_ quarter: String) throws -> Bool {
        try execute("CREATE TABLE IF NOT EXISTS imported_quarters (quarter TEXT PRIMARY KEY, count INTEGER NOT NULL, imported_at TEXT NOT NULL);")
        let stmt = try prepare("SELECT count FROM imported_quarters WHERE quarter=?;")
        defer { sqlite3_finalize(stmt) }
        bind(stmt,[quarter])
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    func importQuarterArchive(at path: URL, quarter: String) throws -> Int {
        var sourceDB: OpaquePointer?
        guard sqlite3_open_v2(path.path, &sourceDB, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(sourceDB)
            throw LotteryDataError.database("Không mở được tệp lưu trữ " + quarter)
        }
        defer { sqlite3_close(sourceDB) }
        let sql = """
        SELECT d.draw_date, d.region_code, d.province_code,
               r.prize_code, r.prize_order, r.result_number
        FROM lottery_draws d JOIN lottery_results r ON r.draw_key=d.draw_key
        ORDER BY d.draw_date, d.region_code, d.province_code, r.prize_code, r.prize_order;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(sourceDB,sql,-1,&stmt,nil) == SQLITE_OK else {
            throw LotteryDataError.database("Lược đồ lưu trữ không tương thích " + quarter)
        }
        defer { sqlite3_finalize(stmt) }
        var batch: [LotteryResult] = []
        var inserted = 0
        func stringAt(_ i: Int32) -> String {
            guard let value=sqlite3_column_text(stmt,i) else { return "" }
            return String(cString:value)
        }
        func normalizedRegion(_ raw: String) -> String? {
            let s=raw.uppercased().trimmingCharacters(in:.whitespacesAndNewlines)
            switch s {
            case "MB", "B", "NORTH", "XSMB": return "MB"
            case "MT", "T", "CENTRAL", "XSMT": return "MT"
            case "MN", "N", "SOUTH", "XSMN": return "MN"
            default: return nil
            }
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let regionRaw=stringAt(1)
            guard let region=normalizedRegion(regionRaw) else {
                throw LotteryDataError.database("Mã miền không hỗ trợ: "+regionRaw)
            }
            let row=LotteryResult(date:stringAt(0), region:region, station:stringAt(2),
                                  prize:stringAt(3), position:Int(sqlite3_column_int(stmt,4)),
                                  number:stringAt(5), source:"itgi8vn/api-kqxs-archives-quarterly/"+quarter)
            // Historical dataset may begin earlier than our five-year window.
            if row.date < "2021-11-12" { continue }
            batch.append(row)
            if batch.count >= 2000 { inserted += try importRows(batch); batch.removeAll(keepingCapacity:true) }
        }
        if !batch.isEmpty { inserted += try importRows(batch) }
        let containsRecords = inserted > 0 ? true : (try hasQuarterRecords(quarter))
        guard containsRecords else {
            throw LotteryDataError.database("Lưu trữ rỗng hoặc không có dữ liệu hợp lệ: "+quarter)
        }
        try execute("CREATE TABLE IF NOT EXISTS imported_quarters (quarter TEXT PRIMARY KEY, count INTEGER NOT NULL, imported_at TEXT NOT NULL);")
        let marker=try prepare("INSERT OR REPLACE INTO imported_quarters(quarter,count,imported_at) VALUES(?,?,?);")
        defer { sqlite3_finalize(marker) }
        bind(marker,[quarter,String(inserted),ISO8601DateFormatter().string(from:Date())])
        guard sqlite3_step(marker) == SQLITE_DONE else { throw LotteryDataError.database("Không lưu được mốc đồng bộ") }
        return inserted
    }
    private func hasQuarterRecords(_ quarter: String) throws -> Bool {
        let parts=quarter.split(separator:"Q")
        guard parts.count == 2, let year=Int(parts[0]), let q=Int(parts[1]) else { return false }
        let start=String(format:"%04d-%02d-01",year,(q-1)*3+1)
        let end=String(format:"%04d-%02d-01",year,q*3+1)
        let stmt=try prepare("SELECT 1 FROM results WHERE date>=? AND date<? LIMIT 1;")
        defer { sqlite3_finalize(stmt) }
        bind(stmt,[start,end])
        return sqlite3_step(stmt)==SQLITE_ROW
    }
}

struct QuarterSyncSummary {
    var quartersDownloaded=0
    var rowsAdded=0
    var pending:[String]=[]
    var failures:[String]=[]
}

/// No server and no API key: fetch static completed-quarter archives over HTTPS.
enum QuarterArchiveSync {
    static let repository="https://raw.githubusercontent.com/itgi8vn/api-kqxs-archives-quarterly/main/archives"
    static func completedQuarters(now:Date=Date()) -> [(year:Int, quarter:Int, key:String)] {
        let cal=Calendar(identifier:.gregorian)
        let vn=TimeZone(identifier:"Asia/Ho_Chi_Minh")!
        var calendar=cal
        calendar.timeZone=vn
        let year=calendar.component(.year,from:now)
        let month=calendar.component(.month,from:now)
        let currentQuarter=(month-1)/3+1
        var output:[(year:Int,quarter:Int,key:String)]=[]
        for y in 2021...year {
            for q in 1...4 where (y>2021 || q==4) && (y<year || q<currentQuarter) {
                output.append((y,q,"\\(y)Q\\(q)"))
            }
        }
        return output
    }
    @MainActor
    static func synchronize(onProgress:@escaping (String)->Void) async -> QuarterSyncSummary {
        var summary=QuarterSyncSummary()
        let db=LotteryDatabase.shared
        let fm=FileManager.default
        for item in completedQuarters() {
            do {
                if try db.importedQuarter(item.key) { continue }
                onProgress("Đang tải "+item.key)
                let address="\\(repository)/\\(item.year)/Q\\(item.quarter)/kqxs_\\(item.year)_Q\\(item.quarter).sqlite"
                guard let url=URL(string:address) else { continue }
                var request=URLRequest(url:url)
                request.timeoutInterval=45
                let (temp,response)=try await URLSession.shared.download(for:request)
                guard let http=response as? HTTPURLResponse, http.statusCode==200 else {
                    summary.pending.append(item.key)
                    continue
                }
                let destination=fm.temporaryDirectory.appendingPathComponent("lottery-\\(item.key).sqlite")
                try? fm.removeItem(at:destination)
                try fm.moveItem(at:temp,to:destination)
                defer { try? fm.removeItem(at:destination) }
                let count=try db.importQuarterArchive(at:destination,quarter:item.key)
                summary.rowsAdded += count
                summary.quartersDownloaded += 1
            } catch {
                summary.failures.append(item.key+": "+error.localizedDescription)
            }
        }
        return summary
    }
}
