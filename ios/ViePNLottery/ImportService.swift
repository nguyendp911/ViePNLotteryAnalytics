import Foundation

enum CSVReader {
    static func parse(_ content: String) throws -> [LotteryResult] {
        let characters = Array(content.replacingOccurrences(of: "\u{FEFF}", with: ""))
        var rows: [[String]] = [], fields: [String] = [], field = "", inQuotes = false
        var index = 0
        while index < characters.count {
            let char = characters[index]
            if char == "\"" {
                if inQuotes && index + 1 < characters.count && characters[index + 1] == "\"" {
                    field.append("\"")
                    index += 1
                } else { inQuotes.toggle() }
            } else if char == "," && !inQuotes {
                fields.append(field); field = ""
            } else if (char == "\n" || char == "\r") && !inQuotes {
                if char == "\r" && index + 1 < characters.count && characters[index + 1] == "\n" { index += 1 }
                fields.append(field); field = ""
                if fields.contains(where: { !$0.isEmpty }) { rows.append(fields) }
                fields = []
            } else { field.append(char) }
            index += 1
        }
        guard !inQuotes else { throw LotteryDataError.invalidFormat }
        fields.append(field)
        if fields.contains(where: { !$0.isEmpty }) { rows.append(fields) }
        guard let header = rows.first?.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }),
              Set(["date","region","station","prize","position","number","source"]).isSubset(of: Set(header)) else {
            throw LotteryDataError.invalidFormat
        }
        func val(_ values: [String],_ key: String) -> String {
            let at = header.firstIndex(of: key)!
            return at < values.count ? values[at].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        }
        return rows.dropFirst().map { row in
            LotteryResult(date:val(row,"date"),region:val(row,"region"),station:val(row,"station"),
                          prize:val(row,"prize"),position:Int(val(row,"position")) ?? 0,
                          number:val(row,"number"),source:val(row,"source"))
        }
    }
}
struct SyncEnvelope: Decodable {
    let schemaVersion: Int
    let results: [LotteryResult]
    enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", results }
}
enum HTTPSImporter {
    static func fetch(_ address: String) async throws -> [LotteryResult] {
        guard let url = URL(string: address),url.scheme == "https",url.host != nil else { throw LotteryDataError.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data,response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode), data.count < 20_000_000 else {
            throw LotteryDataError.invalidFormat
        }
        let envelope = try JSONDecoder().decode(SyncEnvelope.self, from:data)
        guard envelope.schemaVersion == 1 else { throw LotteryDataError.invalidFormat }
        return envelope.results
    }
}
