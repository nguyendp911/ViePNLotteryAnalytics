import SwiftUI
import UniformTypeIdentifiers
import Charts

@MainActor
final class LotteryModel: ObservableObject {
    @Published var region = "MN"
    @Published var station = ""
    @Published var stations: [StationKey] = []
    @Published var days = 30
    @Published var counts = Array(repeating:0,count:100)
    @Published var sample = 0
    @Published var quality: DataQuality?
    @Published var message = ""
    @Published var busy = false
    @Published var syncURL = UserDefaults.standard.string(forKey:"lottery_sync_url") ?? ""
    private let db = LotteryDatabase.shared

    init() { refresh() }

    func refresh() {
        do {
            stations = try db.stations()
            if !stations.contains(where: { $0.region == region && $0.station == station }) {
                station = stations.first(where: { $0.region == region })?.station ?? ""
            }
            quality = try db.quality()
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")
            let end = formatter.string(from: Date())
            let start = formatter.string(from: Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date())
            let result = try db.frequencies(region:region,station:station,since:start,until:end)
            counts = result.counts
            sample = result.sample
        } catch { message = error.localizedDescription }
    }

    func importCSV(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let content = try String(contentsOf:url,encoding:.utf8)
            let inserted = try db.importRows(CSVReader.parse(content))
            message = "Đã nhập \(inserted) kết quả."
            refresh()
        } catch { message = error.localizedDescription }
    }
    func synchronize() async {
        busy = true
        defer { busy = false }
        do {
            let records = try await HTTPSImporter.fetch(syncURL)
            let count = try db.importRows(records)
            UserDefaults.standard.set(syncURL,forKey:"lottery_sync_url")
            message = "Đã đồng bộ \(count) kết quả. Chưa xác minh đủ dữ liệu 5 năm."
            refresh()
        } catch { message = error.localizedDescription }
    }
}

struct ContentView: View {
    @StateObject private var model = LotteryModel()
    @State private var importing = false
    private let columns = Array(repeating: GridItem(.flexible(),spacing:5),count:5)
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    VStack(alignment:.leading,spacing:4) {
                        Text("ViePN Lottery Analytics").font(.title2.bold())
                        Text("Thống kê kết quả đã công bố · Không dự đoán kết quả").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing:8) {
                        stat("Kết quả",model.quality?.resultCount ?? 0)
                        stat("Kỳ/đài",model.quality?.drawCount ?? 0)
                        stat("Nguồn",model.quality?.sourceCount ?? 0)
                    }
                    Label("Chưa xác minh đủ 5 năm dữ liệu. Thống kê dựa trên dữ liệu đã nhập.",systemImage:"exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange)
                    Picker("Miền",selection:$model.region) {
                        Text("Miền Bắc").tag("MB"); Text("Miền Trung").tag("MT"); Text("Miền Nam").tag("MN")
                    }.pickerStyle(.segmented)
                        .onChange(of:model.region) { _,_ in model.refresh() }
                    let choices = model.stations.filter { $0.region == model.region }
                    if !choices.isEmpty {
                        Picker("Đài",selection:$model.station) {
                            ForEach(choices) { entry in Text(entry.station).tag(entry.station) }
                        }.onChange(of:model.station) { _,_ in model.refresh() }
                    }
                    Picker("Khoảng thời gian",selection:$model.days) {
                        Text("7 ngày").tag(7); Text("30 ngày").tag(30)
                        Text("90 ngày").tag(90); Text("365 ngày").tag(365)
                        Text("5 năm").tag(1826)
                    }.onChange(of:model.days) { _,_ in model.refresh() }
                    Text("Tần suất hai chữ số cuối — \(model.sample) kết quả").font(.headline)
                    if model.sample == 0 {
                        ContentUnavailableView("Chưa có dữ liệu",systemImage:"chart.bar.xaxis",
                            description:Text("Nhập CSV hoặc đồng bộ JSON HTTPS để bắt đầu."))
                    } else {
                        Chart(0..<100,id:\.self) { number in
                            BarMark(x:.value("Số",String(format:"%02d",number)),y:.value("Lượt",model.counts[number]))
                        }.chartXAxis(.hidden).frame(height:140)
                        LazyVGrid(columns:columns,spacing:5) {
                            ForEach(0..<100,id:\.self) { number in
                                VStack(spacing:3) {
                                    Text(String(format:"%02d",number)).font(.system(.subheadline,design:.monospaced).bold())
                                    Text("\(model.counts[number])").font(.caption2).foregroundStyle(.secondary)
                                }.frame(maxWidth:.infinity).padding(.vertical,8)
                                    .background(Color.blue.opacity(0.04+0.38*Double(model.counts[number])/Double(max(1,model.counts.max() ?? 1))))
                                    .clipShape(RoundedRectangle(cornerRadius:7))
                            }
                        }
                    }
                    Divider()
                    Text("Dữ liệu lưu trên iPhone").font(.headline)
                    Text("Mục tiêu: 12/11/2021 đến hiện tại.").font(.footnote).foregroundStyle(.secondary)
                    Text("Từ: \(model.quality?.earliest ?? "—") · Đến: \(model.quality?.latest ?? "—")")
                        .font(.footnote)
                    Button { importing = true } label: {
                        Label("Nhập CSV",systemImage:"square.and.arrow.down")
                    }.buttonStyle(.borderedProminent)
                    TextField("https://example.com/lottery.json",text:$model.syncURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL).textFieldStyle(.roundedBorder)
                    Button { Task { await model.synchronize() } } label: {
                        if model.busy { ProgressView() } else {
                            Label("Đồng bộ JSON qua HTTPS",systemImage:"arrow.triangle.2.circlepath")
                        }
                    }.disabled(model.busy).buttonStyle(.bordered)
                    if !model.message.isEmpty { Text(model.message).font(.footnote).foregroundStyle(.secondary) }
                    Text("Thống kê lịch sử không bảo đảm kết quả trong tương lai.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding()
            }.navigationTitle("Thống kê").navigationBarTitleDisplayMode(.inline)
                .fileImporter(isPresented:$importing,allowedContentTypes:[.commaSeparatedText,.plainText]) { result in
                    switch result {
                    case .success(let url): model.importCSV(url)
                    case .failure(let error): model.message = error.localizedDescription
                    }
                }
        }
    }
    private func stat(_ label:String,_ value:Int) -> some View {
        VStack(spacing:4) {
            Text(value.formatted()).font(.headline)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth:.infinity).padding(12)
            .background(.thinMaterial,in:RoundedRectangle(cornerRadius:10))
    }
}
