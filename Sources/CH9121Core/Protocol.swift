import Foundation

public enum CHError: Error, LocalizedError {
    case invalid(String), network(String), timeout, cancelled
    public var errorDescription: String? {
        switch self {
        case .invalid(let s), .network(let s): return s
        case .timeout: return "裝置未回應。請確認網卡、供電、網線，以及 macOS 的區域網路權限。"
        case .cancelled: return "操作已取消。"
        }
    }
}

public enum Command: UInt8, Sendable {
    case set = 0x01, get = 0x02, factoryReset = 0x03, search = 0x04
    case setACK = 0x81, getACK = 0x82, resetACK = 0x83, searchACK = 0x84
}

public enum Wire {
    public static let magic = Array("CH9121_CFG_FLAG\0".utf8)
    public static let packetSize = 285
    public static let headerSize = 30
    public static let configSize = 204
    public static let hostPort: UInt16 = 60000
    public static let devicePort: UInt16 = 50000

    public static func macBytes(_ text: String) throws -> [UInt8] {
        let parts = text.replacingOccurrences(of: "-", with: ":").split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6 else { throw CHError.invalid("MAC 位址格式錯誤。") }
        let bytes = parts.compactMap { $0.count == 2 ? UInt8($0, radix: 16) : nil }
        guard bytes.count == 6 else { throw CHError.invalid("MAC 位址格式錯誤。") }
        return bytes
    }
    public static func macText(_ b: [UInt8]) -> String {
        b.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
    public static func ipv4(_ text: String) throws -> [UInt8] {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) else {
            throw CHError.invalid("IPv4 位址格式錯誤：\(text)")
        }
        let b = parts.compactMap { UInt8($0) }
        guard b.count == 4 else { throw CHError.invalid("IPv4 位址超出範圍：\(text)") }
        return b
    }
    public static func ipText(_ b: ArraySlice<UInt8>) -> String { b.map(String.init).joined(separator: ".") }
    public static func text(_ b: ArraySlice<UInt8>) -> String {
        let data = Data(b.prefix(while: { $0 != 0 }))
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }
    static func u16(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | Int(b[o+1]) << 8 }
    static func u32(_ b: [UInt8], _ o: Int) -> Int {
        Int(b[o]) | Int(b[o+1]) << 8 | Int(b[o+2]) << 16 | Int(b[o+3]) << 24
    }
    static func put(_ value: Int, into b: inout [UInt8], at o: Int, width: Int) {
        for i in 0..<width { b[o+i] = UInt8(truncatingIfNeeded: value >> (i*8)) }
    }

    public static func request(_ command: Command, mac: String? = nil, hostMAC: String? = nil,
                               payload: [UInt8]? = nil) throws -> [UInt8] {
        guard [.search, .get, .set, .factoryReset].contains(command) else {
            throw CHError.invalid("不能將回應命令作為請求送出。")
        }
        var b = [UInt8](repeating: 0, count: packetSize)
        b.replaceSubrange(0..<16, with: magic)
        b[16] = command.rawValue
        if command != .search {
            guard let mac else { throw CHError.invalid("操作必須指定裝置 MAC。") }
            let target = try macBytes(mac)
            guard target != [UInt8](repeating: 0, count: 6), target[0] & 1 == 0 else {
                throw CHError.invalid("拒絕對零位址、群播或廣播 MAC 寫入／讀取。")
            }
            b.replaceSubrange(17..<23, with: target)
            if let hostMAC { b.replaceSubrange(23..<29, with: try macBytes(hostMAC)) }
        }
        if command == .set {
            guard let payload, payload.count >= configSize, payload.count <= 255 else {
                throw CHError.invalid("寫入需要完整的 204-byte 設定資料。")
            }
            b[29] = UInt8(configSize)
            b.replaceSubrange(30..<(30+payload.count), with: payload)
        } else if payload != nil {
            throw CHError.invalid("這個命令不應帶有設定資料。")
        }
        return b
    }
}

public struct Packet: Sendable {
    public let bytes: [UInt8]
    public var command: UInt8 { bytes[16] }
    public var mac: String { Wire.macText(Array(bytes[17..<23])) }
    public var hostMAC: String { Wire.macText(Array(bytes[23..<29])) }
    public var length: Int { Int(bytes[29]) }
    public var data: [UInt8] { Array(bytes.dropFirst(30)) }
    public init(_ bytes: [UInt8]) throws {
        guard bytes.count >= 30, bytes.count <= 285, Array(bytes.prefix(16)) == Wire.magic else {
            throw CHError.invalid("非 CH9121 基本協定封包，或封包長度錯誤。")
        }
        self.bytes = bytes
    }
    public func discovery() throws -> DeviceSummary {
        guard command == Command.searchACK.rawValue, length >= 5, length <= 25,
              bytes.count > 30+length else { throw CHError.invalid("搜尋回應不完整。") }
        let nameBytes = bytes[34..<(30+length)]
        guard nameBytes.last == 0 else { throw CHError.invalid("搜尋回應的名稱未終止。") }
        return DeviceSummary(mac: mac, name: Wire.text(nameBytes), ip: Wire.ipText(bytes[30..<34]),
                             version: Int(bytes[30+length]))
    }
    public func configuration() throws -> DeviceConfiguration {
        guard command == Command.getACK.rawValue else { throw CHError.invalid("這不是讀取設定的回應。") }
        guard length == Wire.configSize, data.count >= Wire.configSize else {
            throw CHError.invalid("不支援的設定長度 \(length)；已拒絕解析／寫入，避免破壞不同韌體的欄位。")
        }
        let config = try DeviceConfiguration(payload: data)
        guard config.mac == mac else { throw CHError.invalid("回應與設定資料的 MAC 不一致。") }
        return config
    }
}

public struct DeviceSummary: Identifiable, Equatable, Sendable {
    public let mac: String
    public var name: String
    public var ip: String
    public var version: Int
    public var id: String { mac }
    public init(mac: String, name: String, ip: String, version: Int) {
        self.mac = mac; self.name = name; self.ip = ip; self.version = version
    }
}

public struct PortConfiguration: Equatable, Sendable {
    public var enabled: Bool
    public var mode: Int
    public var randomLocalPort: Bool
    public var localPort: Int
    public var destinationIP: String
    public var destinationPort: Int
    public var baud: Int
    public var dataBits: Int
    public var stopBits: Int
    public var parity: Int
    public var closeOnDisconnect: Bool
    public var packetLength: Int
    public var packetTimeout: Int
    public var clearOnConnect: Bool
    public var useDomain: Bool
    public var domain: String

    init(_ b: [UInt8], offset o: Int) {
        enabled = b[o+1] == 1; mode = Int(b[o+2]); randomLocalPort = b[o+3] == 1
        localPort = Wire.u16(b, o+4); destinationIP = Wire.ipText(b[(o+6)..<(o+10)])
        destinationPort = Wire.u16(b, o+10); baud = Wire.u32(b, o+12)
        dataBits = Int(b[o+16]); stopBits = Int(b[o+17]); parity = Int(b[o+18])
        closeOnDisconnect = b[o+19] == 1; packetLength = Wire.u32(b, o+20)
        packetTimeout = Wire.u32(b, o+24); clearOnConnect = b[o+29] == 1
        useDomain = b[o+30] == 1; domain = Wire.text(b[(o+31)..<(o+51)])
    }

    public func validate(label: String) throws {
        guard enabled else { return }
        guard (0...3).contains(mode) else { throw CHError.invalid("\(label)：未知的網路模式。") }
        guard (0...65535).contains(localPort), (randomLocalPort && mode == 1) || localPort > 0,
              (0...65535).contains(destinationPort), (mode != 1 && mode != 3) || destinationPort > 0 else {
            throw CHError.invalid("\(label)：本地／目的埠必須有效；Client 的目的埠不可為 0。")
        }
        _ = try Wire.ipv4(destinationIP)
        guard (300...921600).contains(baud) else { throw CHError.invalid("\(label)：本版基本設定支援 300～921600 baud（包含 512000）。") }
        guard (5...8).contains(dataBits), [1, 2].contains(stopBits), (0...4).contains(parity) else {
            throw CHError.invalid("\(label)：資料位、停止位或校驗值無效；未知讀回值不會自動轉換。")
        }
        guard (1...1024).contains(packetLength), (0...200).contains(packetTimeout) else {
            throw CHError.invalid("\(label)：RX 長度須為 1～1024，逾時原始值須為 0～200。")
        }
        guard domain.utf8.count <= 20, !domain.contains("\0") else { throw CHError.invalid("\(label)：域名最多 20 bytes，不能含 NUL。") }
        if useDomain {
            guard !domain.isEmpty, domain.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 }) else {
                throw CHError.invalid("\(label)：請輸入 ASCII 域名，不要加入 http://、路徑或空白。")
            }
        }
    }

    func patch(into b: inout [UInt8], offset o: Int) throws {
        let before = PortConfiguration(b, offset: o)
        func flag(_ offset: Int, _ value: Bool, _ old: Bool) {
            if value != old { b[o+offset] = value ? 1 : 0 }
        }
        flag(1, enabled, before.enabled)
        // Disabled ports are still preserved byte-for-byte unless explicitly changed.
        let integers: [(Int, Int, Int, Int)] = [
            (2,mode,before.mode,1), (4,localPort,before.localPort,2), (10,destinationPort,before.destinationPort,2),
            (12,baud,before.baud,4), (16,dataBits,before.dataBits,1), (17,stopBits,before.stopBits,1),
            (18,parity,before.parity,1), (20,packetLength,before.packetLength,4), (24,packetTimeout,before.packetTimeout,4)
        ]
        for (offset,value,old,width) in integers where value != old { Wire.put(value, into: &b, at: o+offset, width: width) }
        flag(3,randomLocalPort,before.randomLocalPort); flag(19,closeOnDisconnect,before.closeOnDisconnect)
        flag(29,clearOnConnect,before.clearOnConnect); flag(30,useDomain,before.useDomain)
        if destinationIP != before.destinationIP { b.replaceSubrange((o+6)..<(o+10), with: try Wire.ipv4(destinationIP)) }
        if domain != before.domain {
            guard domain.utf8.count <= 20 else { throw CHError.invalid("域名過長。") }
            b.replaceSubrange((o+31)..<(o+51), with: Array(domain.utf8) + [UInt8](repeating: 0, count: 20-domain.utf8.count))
        }
    }
}

public struct DeviceConfiguration: Equatable, Sendable {
    // Keep the entire returned payload, including 51 trailing/reserved bytes.
    public private(set) var originalPayload: [UInt8]
    public let mac: String
    public var name: String
    public var ip: String
    public var gateway: String
    public var netmask: String
    public var dhcp: Bool
    public var serialNegotiation: Bool
    public var port1: PortConfiguration
    public var port2: PortConfiguration

    public init(payload: [UInt8]) throws {
        guard payload.count >= 204, payload.count <= 255 else { throw CHError.invalid("設定資料長度不符。") }
        var b = payload
        b += [UInt8](repeating: 0, count: 255-b.count)
        originalPayload = b
        mac = Wire.macText(Array(b[26..<32])); name = Wire.text(b[5..<26])
        ip = Wire.ipText(b[32..<36]); gateway = Wire.ipText(b[36..<40]); netmask = Wire.ipText(b[40..<44])
        dhcp = b[44] == 1; serialNegotiation = b[65] == 1
        // Wire order is auxiliary UART2 FIRST, primary UART1 SECOND.
        port2 = PortConfiguration(b, offset: 74)
        port1 = PortConfiguration(b, offset: 139)
    }
    public func validate() throws {
        guard !name.isEmpty, name.utf8.count <= 20, !name.contains("\0") else { throw CHError.invalid("設備名稱須為 1～20 bytes，不可包含 NUL。") }
        let address = try Wire.ipv4(ip)
        _ = try Wire.ipv4(gateway)
        let mask = try Wire.ipv4(netmask)
        let m = mask.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let inverted = ~m
        guard inverted & (inverted &+ 1) == 0 else { throw CHError.invalid("子網路遮罩必須由連續的 1 組成。") }
        if !dhcp {
            guard address != [0,0,0,0], address[0] > 0, address[0] != 127, address[0] < 224,
                  address != [255,255,255,255], m != 0 else { throw CHError.invalid("靜態設備 IP／遮罩無效。") }
            let ipInt = address.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            if inverted > 1, ipInt & inverted == 0 || ipInt & inverted == inverted {
                throw CHError.invalid("靜態 IP 不可使用該子網的網路位址或廣播位址。")
            }
        }
        guard port1.enabled else { throw CHError.invalid("本工具不允許關閉主要串口 1。") }
        try port1.validate(label: "串口 1"); try port2.validate(label: "串口 2")
    }
    public func encodedPayload() throws -> [UInt8] {
        try validate()
        var b = originalPayload
        let old = try DeviceConfiguration(payload: originalPayload)
        if name != old.name {
            b.replaceSubrange(5..<26, with: Array(name.utf8) + [UInt8](repeating: 0, count: 21-name.utf8.count))
        }
        for (offset,value,previous) in [(32,ip,old.ip),(36,gateway,old.gateway),(40,netmask,old.netmask)] where value != previous {
            b.replaceSubrange(offset..<(offset+4), with: try Wire.ipv4(value))
        }
        if dhcp != old.dhcp { b[44] = dhcp ? 1 : 0 }
        if serialNegotiation != old.serialNegotiation { b[65] = serialNegotiation ? 1 : 0 }
        try port2.patch(into: &b, offset: 74); try port1.patch(into: &b, offset: 139)
        return b
    }
    public mutating func copyEditableSettings(from other: DeviceConfiguration) {
        // Never import MAC, firmware identity, port indices, or reserved bytes from another device.
        name=other.name; ip=other.ip; gateway=other.gateway; netmask=other.netmask
        dhcp=other.dhcp; serialNegotiation=other.serialNegotiation; port1=other.port1; port2=other.port2
    }
    public mutating func applyLidarPreset(_ model: String, receiverIP: String) throws {
        let speeds = ["M10":460800, "M10P":512000, "N10":230400, "N10P":460800]
        guard let speed = speeds[model] else { throw CHError.invalid("未知的光達型號。") }
        _ = try Wire.ipv4(receiverIP)
        port1.enabled=true; port1.mode=3; port1.randomLocalPort=false
        port1.localPort=2369; port1.destinationPort=2368; port1.destinationIP=receiverIP
        port1.useDomain=false; port1.baud=speed; port1.dataBits=8; port1.stopBits=1; port1.parity=4
        port1.packetLength=1024; port1.packetTimeout=0; port1.closeOnDisconnect=true; port1.clearOnConnect=false
    }
    public func differences(from old: DeviceConfiguration, ignoreDynamicAddress: Bool = false) -> [String] {
        var result: [String] = []
        func compare<T: Equatable>(_ name: String, _ lhs: T, _ rhs: T) {
            if lhs != rhs { result.append("\(name)：\(rhs) → \(lhs)") }
        }
        compare("名稱",name,old.name); compare("DHCP",dhcp,old.dhcp)
        if !(ignoreDynamicAddress && dhcp && old.dhcp) {
            compare("設備 IP",ip,old.ip); compare("閘道",gateway,old.gateway); compare("遮罩",netmask,old.netmask)
        }
        compare("串口協商",serialNegotiation,old.serialNegotiation)
        for (n,p,q) in [(1,port1,old.port1),(2,port2,old.port2)] {
            compare("串口 \(n) 啟用",p.enabled,q.enabled)
            let prefix = "串口 \(n) "
            compare(prefix+"模式",p.mode,q.mode); compare(prefix+"隨機本地埠",p.randomLocalPort,q.randomLocalPort)
            compare(prefix+"本地埠",p.localPort,q.localPort); compare(prefix+"目的 IP",p.destinationIP,q.destinationIP)
            compare(prefix+"目的埠",p.destinationPort,q.destinationPort); compare(prefix+"baud",p.baud,q.baud)
            compare(prefix+"資料位",p.dataBits,q.dataBits); compare(prefix+"停止位",p.stopBits,q.stopBits)
            compare(prefix+"校驗",p.parity,q.parity); compare(prefix+"斷線處理",p.closeOnDisconnect,q.closeOnDisconnect)
            compare(prefix+"RX 長度",p.packetLength,q.packetLength); compare(prefix+"RX 逾時",p.packetTimeout,q.packetTimeout)
            compare(prefix+"清空緩衝",p.clearOnConnect,q.clearOnConnect); compare(prefix+"域名模式",p.useDomain,q.useDomain)
            compare(prefix+"域名",p.domain,q.domain)
        }
        return result
    }
    public static func demo() -> DeviceConfiguration {
        var b = [UInt8](repeating: 0, count: 255)
        b.replaceSubrange(0..<5, with: [0x21,0x21,1,2,2])
        b.replaceSubrange(5..<12, with: Array("CH9121\0".utf8))
        b.replaceSubrange(26..<32, with: [2,0,0,0x91,0x21,1])
        b.replaceSubrange(32..<36, with: [192,168,1,200])
        b.replaceSubrange(36..<40, with: [192,168,1,1]); b.replaceSubrange(40..<44, with: [255,255,255,0])
        b[64]=255
        for o in [74,139] {
            b[o] = o == 139 ? 1 : 0; b[o+1] = o == 139 ? 1 : 0; b[o+2]=1
            Wire.put(o == 139 ? 2000 : 3000, into: &b, at: o+4, width: 2)
            b.replaceSubrange((o+6)..<(o+10), with: [192,168,1,100])
            Wire.put(1000, into: &b, at: o+10, width: 2); Wire.put(9600, into: &b, at: o+12, width: 4)
            b[o+16]=8; b[o+17]=1; b[o+18]=4; b[o+19]=1
            Wire.put(1024, into: &b, at: o+20, width: 4)
        }
        return try! DeviceConfiguration(payload: b) // fixed-size internal demonstration fixture only
    }
}

public struct ConfigurationArchive: Codable {
    public let format: String
    public let version: Int
    public let createdAt: Date
    public let sourceMAC: String
    public let payload: Data
    public init(config: DeviceConfiguration) throws {
        format="CH9121ConfigBackup"; version=1; createdAt=Date(); sourceMAC=config.mac
        payload=Data(try config.encodedPayload())
    }
    public func configuration() throws -> DeviceConfiguration {
        guard format == "CH9121ConfigBackup", version == 1, payload.count == 255 else {
            throw CHError.invalid("不是支援的 CH9121 Config JSON 備份；不支援原廠未公開的 .cfg 格式。")
        }
        let c = try DeviceConfiguration(payload: Array(payload))
        guard c.mac == sourceMAC else { throw CHError.invalid("備份 MAC 與資料不一致。") }
        try c.validate(); return c
    }
    public func json() throws -> Data {
        let encoder=JSONEncoder(); encoder.outputFormatting=[.prettyPrinted,.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
    public static func load(_ data: Data) throws -> ConfigurationArchive {
        guard data.count < 128*1024 else { throw CHError.invalid("備份檔過大。") }
        let decoder=JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let archive=try decoder.decode(ConfigurationArchive.self,from:data)
        _ = try archive.configuration(); return archive
    }
}
