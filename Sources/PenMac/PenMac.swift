import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PenCore

@MainActor
final class Workspace: ObservableObject {
    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        let report: ArtifactReport?
        let error: String?
    }
    @Published var items: [Item] = []
    @Published var selection: UUID?
    @Published var busy = false
    @Published var message: String?
    struct Outcome {
        let source: URL
        let destination: URL
        let title: String
        let summary: String
        let note: String
    }
    @Published var outcome: Outcome?
    @Published var progressText = "正在读取文件…"
    func completed(source: URL, destination: URL, title: String, summary: String, note: String = "") {
        outcome = Outcome(source: source, destination: destination, title: title, summary: summary, note: note)
    }
    struct NODSetup: Identifiable, Sendable {
        let id = UUID()
        let source: URL
        let firmware: URL
        let codes: Set<UInt32>
        let suggestedCode: UInt32
        let suggestedBookID: UInt32
    }
    @Published var nodSetup: NODSetup?
    var pendingNODExport: (NODSetup, UInt32, UInt32)?
    var current: Item? { items.first { $0.id == selection } }

    func chooseFiles() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["bnf", "bnl"].compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "打开点读包"
        panel.message = "选择🐛 BNL 或小时候的🐸 BNF 点读包"
        if panel.runModal() == .OK { load(panel.urls) }
    }
    func load(_ urls: [URL]) {
        guard !busy else { return }
        progressText = "正在识别文件…"
        outcome = nil
        busy = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                var paths: [URL] = []
                for url in urls {
                    if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                            paths.append(contentsOf: enumerator.allObjects.compactMap { $0 as? URL }.filter { ["bnl", "nob", "nod", "nos", "noc", "dab", "bnf", "bin", "chp"].contains($0.pathExtension.lowercased()) })
                        }
                    } else { paths.append(url) }
                }
                return Array(Set(paths)).sorted { $0.path < $1.path }.map { url -> Item in
                    do { return Item(url: url, report: try Inspector.inspect(url), error: nil) }
                    catch { return Item(url: url, report: nil, error: error.localizedDescription) }
                }
            }.value
            let existing = Set(items.map(\.url))
            items.append(contentsOf: result.filter { !existing.contains($0.url) })
            if let opened = result.first { selection = items.first { $0.url == opened.url }?.id }
            busy = false
            if result.count == 1, let report = result.first?.report {
                NSApp.activate(ignoringOtherApps: true)
                if report.format.hasPrefix("🐛 BNL") { convertBNLToBNF() }
                else if report.format.hasPrefix("BNF"), report.details["完整目录"] == "已验证" { convertBNFToBNL() }
            }
        }
    }
    func extractFirmware() {
        guard let source = current?.url else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + "-audio"
        panel.message = "选择一个尚不存在的目录名称，导出固件中的系统音频"
        if panel.runModal() == .OK, let destination = panel.url {
            progressText = "正在导出系统音频…"
            outcome = nil
            busy = true
            Task {
                do {
                    let count = try await Task.detached { try FirmwareAudio.extract(source, to: destination).clips.count }.value
                    completed(source: source, destination: destination, title: "系统音频已导出", summary: "已保存 \(count) 段 MP3。")
                } catch { message = error.localizedDescription }
                busy = false
            }
        }
    }
    func exportReport() {
        guard let report = current?.report else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = report.filename + ".json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            outcome = nil
            do {
                try Inspector.saveReport(report, to: url)
                if let source = current?.url { completed(source: source, destination: url, title: "分析报告已保存", summary: "报告包含文件识别结果和已知限制。") }
            }
            catch { message = error.localizedDescription }
        }
    }
    private func resource(_ name: String, _ ext: String) -> URL? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else {
            message = "应用内置的转换资源缺失，请重新打开完整的点读包转换 App。"
            return nil
        }
        return url
    }
    func chooseBNLFirmware() -> URL? { resource("v103", "bin") }
    func convertBNLToBNF() {
        guard let source = current?.url, let templateURL = resource("target", "bnf"),
              let firmware = chooseBNLFirmware() else { return }
        let output = NSSavePanel()
        output.allowedContentTypes = [UTType(filenameExtension: "bnf")!]
        output.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + "-音频版.bnf"
        output.message = "保存音频版 BNF 和转换报告；仅转换点读播放，省略非音频事件"
        guard output.runModal() == .OK, let destination = output.url else { return }
        progressText = "正在生成 BNF 并核对音频与点读码…"
        outcome = nil; busy = true
        Task {
            do {
                let report = try await Task.detached(priority: .userInitiated) {
                    let context = try BNLContext(firmware: Data(contentsOf: firmware, options: .mappedIfSafe))
                    let book = try BNLBook(data: Data(contentsOf: source, options: .mappedIfSafe), context: context)
                    let result = try BNLToBNFConverter.convert(book, template: Data(contentsOf: templateURL), nonAudio: .omitWithReport)
                    try ConversionFiles.save(result.data, report: result.report, to: destination)
                    return result.report
                }.value
                completed(source: source, destination: destination, title: "音频版 BNF 已生成",
                          summary: "已转换 \(report.mappedRouteCount) 个点读码、\(report.mediaCount) 段音频。",
                          note: "省略 \(report.omittedEventFieldOffsets.count) 项非音频事件。文件回读核对通过，尚未实机验证。模板身份字段保留；冲突检查仅覆盖输出目录，不等于已检查整支笔。装笔前请查看转换报告。")
            } catch { message = error.localizedDescription }
            busy = false
        }
    }
    func convertBNFToBNL() {
        guard let source = current?.url, let templateURL = resource("target", "bnl"),
              let firmware = chooseBNLFirmware() else { return }
        let output = NSSavePanel()
        output.allowedContentTypes = [UTType(filenameExtension: "bnl")!]
        output.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + "-音频版.bnl"
        output.message = "保存音频版 BNL 和转换报告；省略系统控制，轮换或随机播放改为固定列表"
        guard output.runModal() == .OK, let destination = output.url else { return }
        progressText = "正在转换并核对音频与点读码…"
        outcome = nil; busy = true
        Task {
            do {
                let report = try await Task.detached(priority: .userInitiated) {
                    let context = try BNLContext(firmware: Data(contentsOf: firmware, options: .mappedIfSafe))
                    let template = try BNLBook(data: Data(contentsOf: templateURL, options: .mappedIfSafe), context: context)
                    let sourceBook = try BNFBook(data: Data(contentsOf: source, options: .mappedIfSafe))
                    let result = try BNFToBNLConverter.convert(sourceBook, template: template, systemControls: .omitWithReport)
                    try ConversionFiles.save(result.data, report: result.report, to: destination, bnlContext: context)
                    return result.report
                }.value
                completed(source: source, destination: destination, title: "音频版 BNL 已生成",
                          summary: "已转换 \(report.routeCount) 个点读码、\(report.mediaCount) 段音频。",
                          note: "省略 \(report.omittedSystemControls.count) 条系统控制。文件回读核对通过，尚未实机验证。冲突检查仅覆盖输出目录。播放行为变化详见同目录转换报告。")
            } catch { message = error.localizedDescription }
            busy = false
        }
    }
    func extractBNF() {
        guard let source = current?.url else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + "-音频"
        panel.message = "选择新目录，保存 MP3 和点读码对应表"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        progressText = "正在解码并核验书籍音频…"
        outcome = nil
        busy = true
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try BNFBook(data: Data(contentsOf: source, options: .mappedIfSafe))
                        .extract(sourceFilename: source.lastPathComponent, to: destination)
                }.value
                let count = result.media.filter { $0.mp3Frames != nil }.count
                completed(source: source, destination: destination, title: "BNF 音频已导出",
                          summary: "已保存 \(count) 段 MP3 和完整点读命令表。",
                          note: result.media.count == count ? "导出音频已通过完整解码校验。" : "另有 \(result.media.count - count) 段媒体无法完整验证，已按原始数据保存。")
            } catch { message = error.localizedDescription }
            busy = false
        }
    }
    func extractBNL() {
        guard let source = current?.url, let firmware = chooseBNLFirmware() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + "-decoded"
        panel.message = "导出书籍音频和点读码映射到新目录"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        progressText = "正在导出书籍音频…"
        outcome = nil
        busy = true
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let context = try BNLContext(firmware: Data(contentsOf: firmware, options: .mappedIfSafe))
                    return try BNLBook(data: Data(contentsOf: source, options: .mappedIfSafe), context: context)
                        .extract(sourceFilename: source.lastPathComponent, to: destination)
                }.value
                let mp3 = result.media.filter { $0.mp3Frames != nil }.count
                completed(source: source, destination: destination, title: "书籍音频已导出", summary: "已保存 \(mp3) 段 MP3 和点读码对应表。", note: "另有 \(result.media.count - mp3) 段未识别媒体按原样保留。替换音频时，请保留导出目录内的同名文件与 manifest.json。")
            } catch { message = error.localizedDescription }
            busy = false
        }
    }
    func rebuildBNL() {
        guard let source = current?.url, let firmware = chooseBNLFirmware() else { return }
        let input = NSOpenPanel()
        input.canChooseDirectories = true
        input.canChooseFiles = false
        input.message = "选择从这份 BNL 导出的音频目录。可替换同名 MP3；保留 manifest.json 与点读映射。"
        guard input.runModal() == .OK, let directory = input.url else { return }
        let output = NSSavePanel()
        output.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + "-rebuilt.bnl"
        output.message = "保存重建 BNL 到新文件；当前保留原包的点读映射"
        guard output.runModal() == .OK, let destination = output.url else { return }
        progressText = "正在重建并核对音频…"
        outcome = nil
        busy = true
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let context = try BNLContext(firmware: Data(contentsOf: firmware, options: .mappedIfSafe))
                    return try BNLBook(data: Data(contentsOf: source, options: .mappedIfSafe), context: context)
                        .rebuild(decodedDirectory: directory, to: destination)
                }.value
                completed(source: source, destination: destination, title: "新的🐛点读包已保存", summary: "替换了 \(result.changedMediaIDs.count) 段音频，点读码对应关系保持一致。", note: "文件回读核对通过，尚未实机验证。")
            } catch { message = error.localizedDescription }
            busy = false
        }
    }
    func prepareNOD() {
        guard let source = current?.url, let firmware = chooseBNLFirmware() else { return }
        progressText = "正在读取可转换的音频点…"
        outcome = nil
        busy = true
        Task {
            do {
                let setup = try await Task.detached(priority: .userInitiated) {
                    let context = try BNLContext(firmware: Data(contentsOf: firmware, options: .mappedIfSafe))
                    let book = try BNLBook(data: Data(contentsOf: source, options: .mappedIfSafe), context: context)
                    let routes = book.routes.filter { !$0.mediaIDs.isEmpty }
                    guard let first = routes.first, routes.allSatisfy({ $0.mediaIDs.count == 1 }) else {
                        throw PenError.invalid("当前 NOD 转换仅支持每个点读码对应一段音频的 BNL。")
                    }
                    return NODSetup(source: source, firmware: firmware, codes: Set(routes.map(\.code)),
                                    suggestedCode: first.code, suggestedBookID: max(1, UInt32(book.sourceSHA256.prefix(8), radix: 16) ?? 1))
                }.value
                nodSetup = setup
            } catch { message = error.localizedDescription }
            busy = false
        }
    }
    func finishNODSetup() {
        guard let (setup, coverCode, bookID) = pendingNODExport else { return }
        pendingNODExport = nil
        let output = NSSavePanel()
        output.nameFieldStringValue = setup.source.deletingPathExtension().lastPathComponent + "-open.nod"
        output.message = "请先保存到 Mac 本地的新文件，再复制到点读笔。开放 NOD 为实验性格式，尚未在 A8S 实机验证。"
        guard output.runModal() == .OK, let destination = output.url else { return }
        progressText = "正在转换并逐点核对音频…"
        outcome = nil
        busy = true
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let context = try BNLContext(firmware: Data(contentsOf: setup.firmware, options: .mappedIfSafe))
                    return try BNLBook(data: Data(contentsOf: setup.source, options: .mappedIfSafe), context: context)
                        .convertToOpenNOD(coverCode: coverCode, bookID: bookID, to: destination)
                }.value
                completed(source: setup.source, destination: destination, title: "开放 NOD 已保存", summary: "\(result.routes.count) 个音频点已逐点核对，声音与原包一致。选书点读码：\(result.coverCode)。", note: "实验性转换，尚未在小时候的🐸 A8S 实机验证。可将文件复制到点读笔后测试。")
            } catch { message = error.localizedDescription }
            busy = false
        }
    }
}

@main
struct PenMacApp: App {
    @StateObject private var model = Workspace()
    var body: some Scene {
        WindowGroup("点读包转换", id: "book-converter") {
            ContentView(model: model)
                .frame(minWidth: 480, maxWidth: 800, minHeight: 400, maxHeight: 600)
                .onOpenURL { model.load([$0]) }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 620, height: 475)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开点读包…") { model.chooseFiles() }.keyboardShortcut("o")
            }
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: Workspace
    @State private var dropActive = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 16) {
                Image(systemName: model.outcome != nil ? "checkmark.circle.fill" : "book.closed.fill")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.teal)
                    .frame(width: 68, height: 68)
                    .background(.teal.opacity(0.10), in: RoundedRectangle(cornerRadius: 20))
                    .accessibilityHidden(true)
                if model.busy {
                    Text(model.progressText).font(.headline)
                    ProgressView().controlSize(.small)
                } else if let result = model.outcome, result.source == model.current?.url {
                    Text(result.title).font(.title.bold())
                    Text(result.destination.lastPathComponent).foregroundStyle(.secondary)
                    Text(result.summary).font(.callout).foregroundStyle(.secondary)
                    Button("在 Finder 中查看") { NSWorkspace.shared.activateFileViewerSelecting([result.destination]) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                } else if let item = model.current {
                    selectedBook(item)
                } else {
                    Text("转换点读包").font(.largeTitle.bold())
                    Text("拖入 🐛 BNL 或 小时候的🐸 BNF 点读包，自动识别转换方向。")
                        .foregroundStyle(.secondary)
                    Button("选择点读包…", action: model.chooseFiles)
                        .buttonStyle(.borderedProminent).controlSize(.large)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 470).padding(24)
            Spacer()
            if model.current != nil {
                Divider()
                HStack {
                    Button("打开其他文件…", action: model.chooseFiles)
                    if model.items.count > 1 {
                        Menu("切换书籍") {
                            ForEach(model.items) { book in
                                Button(book.url.lastPathComponent) { model.selection = book.id; model.outcome = nil }
                            }
                        }
                    }
                    Spacer()
                    if let report = model.current?.report {
                        Menu("更多操作") {
                            if report.format.hasPrefix("🐛 BNL") {
                                Button("导出书籍音频…", action: model.extractBNL)
                                Button("从音频目录重建…", action: model.rebuildBNL)
                                Button("转换为开放 NOD…", action: model.prepareNOD)
                            } else if report.format.hasPrefix("BNF"), report.details["完整目录"] == "已验证" {
                                Button("导出书籍音频…", action: model.extractBNF)
                            } else if report.details["内置 MP3"] != nil {
                                Button("导出系统音频…", action: model.extractFirmware)
                            }
                            Button("保存检查报告…", action: model.exportReport)
                        }.fixedSize()
                    }
                }.padding(14).disabled(model.busy)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(.teal)
        .overlay { if dropActive { RoundedRectangle(cornerRadius: 12).stroke(.tint, lineWidth: 3).padding(6).allowsHitTesting(false) } }
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.busy else { return false }
            model.load(urls)
            return !urls.isEmpty
        } isTargeted: { dropActive = $0 }
        .alert("操作未完成", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("好", role: .cancel) { model.message = nil }
        } message: { Text(model.message ?? "") }
        .sheet(item: $model.nodSetup, onDismiss: { model.finishNODSetup() }) { setup in
            NODConversionSheet(setup: setup) { coverCode, bookID in
                model.pendingNODExport = (setup, coverCode, bookID)
                model.nodSetup = nil
            } cancel: { model.nodSetup = nil }
        }
    }

    @ViewBuilder private func selectedBook(_ item: Workspace.Item) -> some View {
        let isBNL = item.report?.format.hasPrefix("🐛 BNL") == true
        let isBNF = item.report?.format.hasPrefix("BNF") == true && item.report?.details["完整目录"] == "已验证"
        Text(item.url.deletingPathExtension().lastPathComponent)
            .font(.title2.bold()).lineLimit(2).truncationMode(.middle)
        if isBNL || isBNF {
            Text(isBNL ? "🐛 BNL → 小时候的🐸 BNF" : "小时候的🐸 BNF → 🐛 BNL").font(.headline)
            Button(isBNL ? "转换为 小时候的🐸 BNF 音频包…" : "转换为 🐛 BNL 音频包…") {
                if isBNL { model.convertBNLToBNF() } else { model.convertBNFToBNL() }
            }.buttonStyle(.borderedProminent).controlSize(.large)
            Text("仅转换点读音频 · 尚未实机验证").font(.caption).foregroundStyle(.secondary)
        } else {
            Text(item.error ?? "这个文件暂不支持点读包互转。")
                .foregroundStyle(.secondary)
        }
    }
}

struct NODConversionSheet: View {
    let setup: Workspace.NODSetup
    let save: (UInt32, UInt32) -> Void
    let cancel: () -> Void
    @State private var coverText: String
    @State private var bookText: String
    @State private var advanced = false
    init(setup: Workspace.NODSetup, save: @escaping (UInt32, UInt32) -> Void, cancel: @escaping () -> Void) {
        self.setup = setup; self.save = save; self.cancel = cancel
        _coverText = State(initialValue: String(setup.suggestedCode))
        _bookText = State(initialValue: String(setup.suggestedBookID))
    }
    var coverCode: UInt32? { UInt32(coverText) }
    var bookID: UInt32? {
        let text = bookText.trimmingCharacters(in: .whitespaces)
        return !text.isEmpty && text.utf8.allSatisfy({ (48...57).contains($0) }) ? UInt32(text) : nil
    }
    var valid: Bool { coverCode.map { setup.codes.contains($0) } == true && bookID.map { $0 > 0 } == true }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("设置选书点").font(.title2.bold())
            Text("目标：小时候的🐸开放 NOD（实验性）").foregroundStyle(.secondary)
            Text("选书点是用笔轻点后、切换到这本书的那个点。它原来的声音会保留，其他音频点继续使用原码。")
                .fixedSize(horizontal: false, vertical: true)
            Picker("选书点读码", selection: $coverText) {
                ForEach(setup.codes.sorted(), id: \.self) { code in
                    Text(code == setup.suggestedCode ? "\(code)（原包第一个音频点）" : String(code)).tag(String(code))
                }
            }
            Text("默认点不一定是纸质书的封面。如果知道封面的实际点读码，请从列表中选择；目前不能自动识别纸面位置。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("高级设置", isExpanded: $advanced) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("本地书籍编号", text: $bookText)
                    Text("已自动填写，用于区分点读包。同一支笔上的书籍编号应避免重复；通常无需修改。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 10)
            }
            if bookID == nil || bookID == 0 {
                Text("请展开高级设置，输入 1…4294967295 的十进制书籍编号。").font(.callout).foregroundStyle(.red)
            }
            Divider()
            Label("已验证文件结构和音频对应关系，尚未在 A8S 实机验证。", systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                Button("选择保存位置…") { if let coverCode, let bookID { save(coverCode, bookID) } }
                    .keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }.padding(24).frame(width: 500)
    }
}
