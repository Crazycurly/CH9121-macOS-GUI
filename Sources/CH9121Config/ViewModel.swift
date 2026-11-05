#if os(macOS)
import AppKit
import Combine
import Foundation
import CH9121Core

struct AppAlert: Identifiable {
    let id=UUID()
    let title: String
    let message: String
}

final class AppModel: ObservableObject {
    @Published var adapters=[NetworkAdapter]()
    @Published var adapterID=""
    @Published var devices=[DeviceSummary]()
    @Published var selection: String?
    @Published var draft=DeviceConfiguration.demo()
    @Published var baseline: DeviceConfiguration?
    @Published var busy=false
    @Published var status="選擇接線的網卡，再按「搜尋設備」。"
    @Published var alert: AppAlert?
    @Published var logs=[String]()
    @Published var packetTrace=false
    @Published var isDemo=false
    @Published var presetModel="M10P"
    @Published var receiverIP=""
    @Published var lastBackup=""
    private let queue=DispatchQueue(label:"org.ch9121config.network",qos:.userInitiated)
    private var token: CancellationToken?
    private var simulated=DeviceConfiguration.demo()
    var adapter: NetworkAdapter? { adapters.first { $0.id == adapterID } }
    var canEdit: Bool { !busy && baseline != nil && baseline?.mac == selection }
    var canRead: Bool { !busy && selection != nil && (isDemo || adapter != nil) }
    var pendingChanges: [String] { baseline.map { draft.differences(from:$0) } ?? [] }

    init(demo: Bool = false) {
        if demo { enableDemo(true) } else { refreshAdapters() }
    }
    func note(_ message: String) {
        let formatter=DateFormatter(); formatter.dateFormat="HH:mm:ss"
        logs.append("\(formatter.string(from:Date()))  \(message)")
        if logs.count>500 { logs.removeFirst(logs.count-500) }
    }
    func showError(_ error: Error) {
        note("錯誤：\(error.localizedDescription)")
        alert=AppAlert(title:"操作未完成",message:error.localizedDescription)
    }
    func refreshAdapters() {
        guard !busy, !isDemo else { return }
        do {
            let old=adapterID
            adapters=try NetworkAdapter.available()
            if !adapters.contains(where:{$0.id == old}) {
                adapterID=adapters.first?.id ?? ""; baseline=nil; devices=[]; selection=nil
            }
            if adapters.isEmpty { status="找不到已啟用且有 IPv4 的實體網卡。請接上 Ethernet 並設定 IPv4。" }
            if receiverIP.isEmpty { receiverIP=adapter?.ip ?? "" }
        } catch { showError(error) }
    }
    func adapterChanged() {
        guard !busy, !isDemo else { return }
        devices=[]; selection=nil; baseline=nil
        receiverIP=adapter?.ip ?? ""
        status="網卡已切換，請重新搜尋。"
    }
    func enableDemo(_ value: Bool) {
        guard !busy else { return }
        isDemo=value; baseline=nil; selection=nil; devices=[]
        if value {
            simulated=DeviceConfiguration.demo()
            adapters=[NetworkAdapter(name:"DEMO",ip:"192.168.1.102",netmask:"255.255.255.0",mac:"02:00:00:91:21:02",index:0)]
            adapterID=adapters[0].id; receiverIP=adapters[0].ip
            devices=[DeviceSummary(mac:simulated.mac,name:simulated.name,ip:simulated.ip,version:34)]
            selection=simulated.mac; draft=simulated; baseline=simulated
            status="示範模式：只操作記憶體內的虛擬裝置，不會傳送任何網路封包。"
            note(status)
        } else {
            adapters=[]; adapterID=""; receiverIP=""
            refreshAdapters(); status="已離開示範模式。請重新搜尋真實裝置。"
        }
    }
    private func execute<T>(_ label: String, work: @escaping (UDPTransport)throws->T, done: @escaping (T)->Void) {
        guard !busy, !isDemo, let adapter else { return }
        busy=true; status=label
        let cancellation=CancellationToken(); token=cancellation
        let detailed=packetTrace
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let transport=try UDPTransport(adapter:adapter,token:cancellation,log:{ [weak self] line in
                    DispatchQueue.main.async { self?.note(line) }
                },trace:{ [weak self] line in
                    if detailed { DispatchQueue.main.async { self?.note(line) } }
                })
                let result=try work(transport)
                DispatchQueue.main.async {
                    self.busy=false; self.token=nil; done(result)
                }
            } catch {
                DispatchQueue.main.async {
                    self.busy=false; self.token=nil; self.baseline=nil
                    self.status="操作未完成；請查看紀錄。"; self.showError(error)
                }
            }
        }
    }
    func scan() {
        guard !busy else { return }
        if isDemo {
            devices=[DeviceSummary(mac:simulated.mac,name:simulated.name,ip:simulated.ip,version:34)]
            selection=simulated.mac; status="示範搜尋：找到 1 個虛擬裝置。"; return
        }
        baseline=nil; selection=nil; devices=[]
        execute("正在搜尋 CH9121…",work: { try $0.discover() },done: { [weak self] result in
            guard let self else { return }
            self.devices=result; self.selection=result.first?.mac
            self.status=result.isEmpty ? "未找到裝置。確認正確網卡、區域網路權限、供電及相同二層網路。" : "找到 \(result.count) 個裝置；雙擊設備或按「讀取設定」。"
        })
    }
    private func accept(_ config: DeviceConfiguration) {
        baseline=config; draft=config
        if let i=devices.firstIndex(where:{$0.mac == config.mac}) { devices[i].name=config.name; devices[i].ip=config.ip }
    }
    func readSelected() {
        guard canRead, let mac=selection else { return }
        if isDemo { accept(simulated); status="已讀取虛擬裝置的設定。"; return }
        execute("正在讀取 \(mac)…",work: { try $0.readConfiguration(mac:mac) },done: { [weak self] config in
            self?.accept(config); self?.status="設定已讀取。修改後需按「寫入設定」才會生效。"
        })
    }
    func applyPreset() {
        guard canEdit else { return }
        do {
            try draft.applyLidarPreset(presetModel,receiverIP:receiverIP)
            status="已填入 \(presetModel) 預設（尚未寫入）；設備 IP／DHCP 與串口 2 維持不變。"
            note(status)
        } catch { showError(error) }
    }
    private func confirm(title: String, message: String, button: String) -> Bool {
        let dialog=NSAlert(); dialog.messageText=title; dialog.informativeText=message; dialog.alertStyle = .warning
        dialog.addButton(withTitle:button); dialog.addButton(withTitle:"取消")
        return dialog.runModal() == .alertFirstButtonReturn
    }
    private func backup(_ config: DeviceConfiguration) throws {
        let root=try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
            .appendingPathComponent("CH9121Config/Backups",isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let timestamp=ISO8601DateFormatter().string(from:Date()).replacingOccurrences(of:":",with:"-")
        let url=root.appendingPathComponent("\(timestamp)-\(config.mac.replacingOccurrences(of:":",with:""))-\(UUID().uuidString.prefix(8)).json")
        try ConfigurationArchive(config:config).json().write(to:url,options:.atomic)
        lastBackup=url.path; note("寫入前備份：\(url.path)")
    }
    func writeSelected() {
        guard canEdit, let baseline, selection == baseline.mac else { return }
        do {
            try draft.validate()
            let changes=pendingChanges
            guard !changes.isEmpty else { status="設定沒有變更；未送出寫入命令。"; return }
            let summary=changes.prefix(14).joined(separator:"\n") + (changes.count>14 ? "\n另有 \(changes.count-14) 項變更。" : "")
            guard confirm(title:isDemo ? "模擬寫入設定？" : "寫入設定並重新啟動模組？",
                          message:"目標 MAC：\(baseline.mac)\n\n\(summary)\n\n真實裝置會中斷目前連線。會先保存本機備份，再送出一次寫入，最後讀回核對。",button:"確認寫入") else { return }
            try backup(baseline)
            let target=draft
            if isDemo {
                simulated=try DeviceConfiguration(payload:target.encodedPayload()); accept(simulated)
                status="模擬寫入與讀回完成；沒有傳送網路封包。"; return
            }
            execute("正在寫入；模組可能短暫離線…",work: { try $0.configure(baseline:baseline,draft:target) },done: { [weak self] result in
                guard let self else { return }
                if result.verified, let c=result.readback {
                    self.accept(c)
                    self.status=result.acknowledged ? "已收到 ACK，並讀回確認設定一致。" : "未收到 ACK，但讀回設定一致；沒有重送寫入。"
                    self.note(self.status)
                } else {
                    self.baseline=nil
                    let detail=result.readback == nil ? "尚未讀回裝置設定。" : "讀回差異：\n"+result.differences.joined(separator:"\n")
                    self.status="寫入結果未確認；請重新搜尋／讀取，不要直接重複寫入。"
                    self.alert=AppAlert(title:"寫入結果未確認",message:"\(result.acknowledged ? "已收到 ACK。" : "未收到 ACK。")\(detail)\n\n\(self.status)\n備份：\(self.lastBackup)")
                    self.note(self.status)
                }
            })
        } catch { showError(error) }
    }
    func restoreFactory() {
        guard canEdit, let baseline else { return }
        guard confirm(title:"恢復出廠設定？",message:"目標 MAC：\(baseline.mac)\n\n這會清除設備的網路與串口設定，M10P 的 512000 baud、UDP Client 等設定也會失效。模組將重新啟動。\n\n這不是一般的重新啟動功能；會先保存備份。",button:"恢復出廠") else { return }
        do { try backup(baseline) } catch { showError(error); return }
        if isDemo { simulated=DeviceConfiguration.demo(); accept(simulated); status="虛擬裝置已還原；未傳送封包。"; return }
        execute("正在還原出廠設定…",work: { try $0.factoryReset(mac:baseline.mac) },done: { [weak self] result in
            guard let self else { return }
            if let c=result.readback { self.accept(c) } else { self.baseline=nil }
            self.status="\(result.acknowledged ? "已收到還原 ACK" : "未收到還原 ACK")；\(result.readback == nil ? "尚未讀回，結果未確認" : "已重新讀取，請核對設定")。"
            self.note(self.status)
            self.alert=AppAlert(title:"還原命令結果",message:self.status+"\n\n備份："+self.lastBackup)
        })
    }
    func saveConfiguration() {
        guard canEdit else { return }
        let panel=NSSavePanel(); panel.nameFieldStringValue="CH9121-\(draft.mac.replacingOccurrences(of:":",with:"" )).json"
        guard panel.runModal() == .OK, let url=panel.url else { return }
        do { try ConfigurationArchive(config:draft).json().write(to:url,options:.atomic); note("已儲存畫面設定：\(url.path)") }
        catch { showError(error) }
    }
    func loadConfiguration() {
        guard canEdit else { return }
        let panel=NSOpenPanel(); panel.canChooseDirectories=false; panel.allowsMultipleSelection=false
        guard panel.runModal() == .OK, let url=panel.url else { return }
        do {
            let archive=try ConfigurationArchive.load(Data(contentsOf:url,options:.mappedIfSafe))
            let imported=try archive.configuration()
            if imported.mac != draft.mac {
                guard confirm(title:"從另一台裝置匯入設定？",message:"備份來自 \(imported.mac)，目前選取 \(draft.mac)。\n只匯入可編輯參數；目標 MAC、韌體識別與保留欄位不會被覆寫。\n\n不會立即寫入裝置。",button:"匯入到畫面") else { return }
            }
            draft.copyEditableSettings(from:imported); status="備份已載入畫面，尚未寫入裝置。"
            note(status)
        } catch { showError(error) }
    }
    func exportLogs() {
        let panel=NSSavePanel(); panel.nameFieldStringValue="CH9121-diagnostics.txt"
        guard panel.runModal() == .OK, let url=panel.url else { return }
        let metadata="CH9121 Config 0.1.0\nOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\nAdapter: \(adapter?.label ?? "none")\nMode: \(isDemo ? "DEMO" : "LIVE")\n\n"
        do { try (metadata+logs.joined(separator:"\n")).write(to:url,atomically:true,encoding:.utf8) }
        catch { showError(error) }
    }
    func revealBackup() {
        guard !lastBackup.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:lastBackup)])
    }
}
#endif
