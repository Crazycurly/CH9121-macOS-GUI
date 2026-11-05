#if os(macOS)
import SwiftUI
import CH9121Core

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var showLog=false
    var body: some View {
        VStack(spacing:0) {
            header
            Divider()
            HSplitView {
                devicePane.frame(minWidth:330,idealWidth:365,maxWidth:480)
                editor.frame(minWidth:610)
            }
            Divider()
            footer
            if showLog {
                Divider()
                ScrollView {
                    Text(model.logs.joined(separator:"\n")).font(.system(size:11,design:.monospaced))
                        .textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding(12)
                }.frame(height:170).background(Color(nsColor:.textBackgroundColor))
            }
        }
        .frame(minWidth:1000,minHeight:720)
        .alert(item:$model.alert) { item in Alert(title:Text(item.title),message:Text(item.message),dismissButton:.default(Text("確定"))) }
        .onChange(of:model.adapterID) { _ in model.adapterChanged() }
    }
    private var header: some View {
        HStack(spacing:14) {
            Image(systemName:"network").font(.system(size:29,weight:.medium)).foregroundStyle(.tint)
                .frame(width:52,height:52).background(.quaternary,in:RoundedRectangle(cornerRadius:12))
            VStack(alignment:.leading,spacing:3) {
                Text("CH9121 Config").font(.title2.weight(.semibold))
                Text("Ethernet → UART  /  macOS 設定工具").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isDemo {
                Label("DEMO · 不傳送封包",systemImage:"testtube.2").font(.caption.weight(.semibold))
                    .padding(8).background(.orange.opacity(0.15),in:RoundedRectangle(cornerRadius:8))
            }
            Button(model.isDemo ? "離開示範" : "示範模式") { model.enableDemo(!model.isDemo) }.disabled(model.busy)
        }.padding(.horizontal,22).padding(.vertical,14)
    }
    private var devicePane: some View {
        VStack(alignment:.leading,spacing:14) {
            Text("01  連線與設備").font(.headline)
            HStack {
                Picker("網卡",selection:$model.adapterID) {
                    if model.adapters.isEmpty { Text("沒有可用 IPv4 網卡").tag("") }
                    ForEach(model.adapters) { Text($0.label).tag($0.id) }
                }.labelsHidden().disabled(model.busy || model.isDemo)
                Button { model.refreshAdapters() } label: { Image(systemName:"arrow.clockwise") }
                    .help("重新列出網卡").disabled(model.busy || model.isDemo)
            }
            if let adapter=model.adapter {
                Text("\(adapter.mac)  ·  \(adapter.netmask)").font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary)
            }
            Button(action:model.scan) {
                Label("搜尋設備",systemImage:"magnifyingglass").frame(maxWidth:.infinity)
            }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.busy || model.adapter == nil)
            Table(model.devices,selection:$model.selection) {
                TableColumn("設備／MAC") { d in
                    VStack(alignment:.leading,spacing:4) {
                        Text(d.name).fontWeight(.medium)
                        Text(d.mac).font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary)
                    }.padding(.vertical,4)
                }
                TableColumn("IP／版本") { d in
                    VStack(alignment:.leading,spacing:4) {
                        Text(d.ip).font(.system(size:11,design:.monospaced))
                        Text(String(format:"v%d · 0x%02X",d.version,d.version)).font(.caption2).foregroundStyle(.secondary)
                    }
                }.width(min:115,ideal:125)
            }.frame(minHeight:160,idealHeight:230,maxHeight:300)
                .onTapGesture(count:2) { model.readSelected() }.disabled(model.busy)
            HStack {
                Button("讀取設定",action:model.readSelected).disabled(!model.canRead)
                Spacer()
                Text("\(model.devices.count) 個設備").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Label("接線提醒",systemImage:"info.circle").font(.subheadline.weight(.semibold))
            Text("選擇實際接到模組的 Ethernet 網卡，不要選 Tailscale／VPN。Mac 與模組須位於同一二層網路；資料接收的 IP 需符合手冊的同網段要求。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            Text("首次使用請允許「區域網路」存取。搜尋使用 UDP 50000／60000，不需要管理員權限。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            Spacer(minLength:0)
            HStack {
                Button("載入設定…",action:model.loadConfiguration).disabled(!model.canEdit)
                Button("儲存設定…",action:model.saveConfiguration).disabled(!model.canEdit)
            }
            Text("使用本工具的 JSON 備份格式；非原廠 .cfg。")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(18)
    }
    private var editor: some View {
        VStack(spacing:0) {
            HStack {
                Text("02  模組參數").font(.headline)
                Spacer()
                Text(model.baseline == nil ? "先讀取設備" : model.pendingChanges.isEmpty ? "已讀取 · 無變更" : "\(model.pendingChanges.count) 項未寫入變更")
                    .font(.caption).foregroundStyle(model.pendingChanges.isEmpty ? Color.secondary : Color.orange)
            }.padding(.horizontal,20).padding(.top,18).padding(.bottom,10)
            ScrollView {
                VStack(spacing:16) {
                    baseSettings
                    presetSettings
                    TabView {
                        PortEditor(port:$model.draft.port1,secondary:false).tabItem { Text("串口 1") }
                        PortEditor(port:$model.draft.port2,secondary:true).tabItem { Text("串口 2") }
                    }.frame(height:440)
                    Text("RX 逾時顯示協定原始值：舊版工具標示 10 ms；CH9121A/T 文件標示 5 ms。0 的行為依韌體定義；本工具不擅自換算。")
                        .font(.caption2).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading)
                }.padding(.horizontal,20).padding(.bottom,18).disabled(!model.canEdit)
            }
            Divider()
            HStack {
                Button("恢復出廠設定…",role:.destructive,action:model.restoreFactory).disabled(!model.canEdit)
                Spacer()
                Button(model.isDemo ? "模擬寫入設定…" : "寫入設定…",action:model.writeSelected)
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!model.canEdit || model.pendingChanges.isEmpty)
            }.padding(16)
        }
    }
    private var baseSettings: some View {
        GroupBox {
            VStack(spacing:10) {
                FieldRow("設備名稱") { TextField("最多 20 bytes",text:$model.draft.name).textFieldStyle(.roundedBorder) }
                FieldRow("MAC（唯讀）") { Text(model.baseline?.mac ?? "—").font(.system(.body,design:.monospaced)).textSelection(.enabled); Spacer() }
                HStack(spacing:20) {
                    Toggle("DHCP 自動取得 IP",isOn:$model.draft.dhcp)
                    Toggle("允許串口協商配置",isOn:$model.draft.serialNegotiation)
                }.font(.caption).frame(maxWidth:.infinity,alignment:.leading)
                HStack(spacing:12) {
                    smallField("設備 IP",text:$model.draft.ip)
                    smallField("子網路遮罩",text:$model.draft.netmask)
                    smallField("預設閘道",text:$model.draft.gateway)
                }.disabled(model.draft.dhcp)
            }.padding(8)
        } label: { Label("基礎設定",systemImage:"slider.horizontal.3") }
    }
    private var presetSettings: some View {
        GroupBox {
            VStack(alignment:.leading,spacing:10) {
                HStack {
                    Picker("光達",selection:$model.presetModel) {
                        ForEach(["M10","M10P","N10","N10P"],id:\.self) { Text($0).tag($0) }
                    }.frame(width:150)
                    TextField("接收電腦 IPv4",text:$model.receiverIP).textFieldStyle(.roundedBorder)
                    Button("填入預設",action:model.applyPreset)
                }
                Text("M10P：UDP Client · 2369 → 2368 · 512000 baud · 8N1。只填入畫面，不會自動寫入；接收 IP 預設取自選取的網卡。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }.padding(8)
        } label: { Label("光達預設",systemImage:"sensor.tag.radiowaves.forward") }
    }
    private func smallField(_ title: String,text: Binding<String>) -> some View {
        VStack(alignment:.leading,spacing:4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title,text:text).textFieldStyle(.roundedBorder).font(.system(size:12,design:.monospaced))
        }
    }
    private var footer: some View {
        HStack(spacing:10) {
            if model.busy { ProgressView().controlSize(.small) }
            else { Circle().fill(model.isDemo ? Color.orange : Color.accentColor).frame(width:7,height:7) }
            Text(model.status).font(.caption).lineLimit(2).textSelection(.enabled)
            Spacer(minLength:8)
            Button { showLog.toggle() } label: { Image(systemName:showLog ? "chevron.down" : "terminal") }.help("通訊紀錄")
            Toggle("封包",isOn:$model.packetTrace).font(.caption).toggleStyle(.checkbox).disabled(model.busy)
            Button("匯出紀錄",action:model.exportLogs).font(.caption)
        }.padding(.horizontal,16).padding(.vertical,10)
    }
}

struct FieldRow<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String,@ViewBuilder content:()->Content) { self.title=title; self.content=content() }
    var body: some View {
        HStack(alignment:.firstTextBaseline,spacing:12) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width:110,alignment:.leading)
            content
        }
    }
}

struct PortEditor: View {
    @Binding var port: PortConfiguration
    let secondary: Bool
    private let modes=["TCP SERVER","TCP CLIENT","UDP SERVER","UDP CLIENT"]
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            if secondary { Toggle("啟用串口 2",isOn:$port.enabled) }
            VStack(spacing:10) {
                FieldRow("網路模式") {
                    Picker("網路模式",selection:$port.mode) {
                        ForEach(0..<4,id:\.self) { Text(modes[$0]).tag($0) }
                        if !(0...3).contains(port.mode) { Text("未知值 \(port.mode)").tag(port.mode) }
                    }.labelsHidden()
                }
                FieldRow("本地埠") {
                    number($port.localPort)
                    Toggle("隨機",isOn:$port.randomLocalPort).disabled(port.mode != 1)
                    Spacer()
                }
                FieldRow("目的地址") {
                    Picker("類型",selection:$port.useDomain) { Text("IP").tag(false); Text("域名").tag(true) }.labelsHidden().frame(width:95)
                    if port.useDomain { TextField("最多 20 bytes",text:$port.domain).textFieldStyle(.roundedBorder) }
                    else { TextField("目的 IPv4",text:$port.destinationIP).textFieldStyle(.roundedBorder) }
                }
                FieldRow("目的埠") { number($port.destinationPort); Spacer() }
                Divider()
                FieldRow("串口 baud") {
                    number($port.baud,width:140)
                    Menu("常用值") { ForEach([9600,19200,38400,57600,115200,230400,460800,512000,921600],id:\.self) { value in
                        Button(String(value)) { port.baud=value }
                    }}.frame(width:100)
                    Spacer()
                }
                HStack(spacing:12) {
                    Picker("資料位",selection:$port.dataBits) {
                        ForEach(5...8,id:\.self) { Text(String($0)).tag($0) }
                        if !(5...8).contains(port.dataBits) { Text("未知 \(port.dataBits)").tag(port.dataBits) }
                    }
                    Picker("停止位",selection:$port.stopBits) {
                        Text("1").tag(1); Text("2").tag(2)
                        if ![1,2].contains(port.stopBits) { Text("未知 \(port.stopBits)").tag(port.stopBits) }
                    }
                    Picker("校驗",selection:$port.parity) {
                        Text("無 (N)").tag(4); Text("奇 (O)").tag(0); Text("偶 (E)").tag(1)
                        Text("Mark").tag(2); Text("Space").tag(3)
                        if !(0...4).contains(port.parity) { Text("未知 \(port.parity)").tag(port.parity) }
                    }
                }.font(.caption)
                Divider()
                FieldRow("RX 打包長度") { number($port.packetLength); Text("1～1024 bytes").font(.caption).foregroundStyle(.secondary); Spacer() }
                FieldRow("RX 逾時原始值") { number($port.packetTimeout); Text("0～200（依韌體定義）").font(.caption).foregroundStyle(.secondary); Spacer() }
                Toggle("網線斷開時，主動關閉網路連線",isOn:$port.closeOnDisconnect)
                Toggle("建立網路連線時，清空串口緩衝區",isOn:$port.clearOnConnect)
            }.disabled(secondary && !port.enabled)
            if secondary { Text("輔助串口 2 的進階行為仍取決於晶片／韌體支援。未修改的資料會保留。").font(.caption2).foregroundStyle(.secondary) }
        }.padding(16)
    }
    private func number(_ value: Binding<Int>,width: CGFloat = 110) -> some View {
        TextField("",value:value,format:.number.grouping(.never))
            .textFieldStyle(.roundedBorder).font(.system(.body,design:.monospaced)).frame(width:width)
    }
}
#endif
