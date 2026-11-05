import Foundation
import CNet

public struct NetworkAdapter: Identifiable, Equatable, Sendable {
    public let name: String
    public let ip: String
    public let netmask: String
    public let mac: String
    public let index: UInt32
    public var id: String { "\(name)|\(ip)" }
    public var label: String { "\(name)  ·  \(ip)" }
    public init(name: String, ip: String, netmask: String, mac: String, index: UInt32) {
        self.name=name; self.ip=ip; self.netmask=netmask; self.mac=mac; self.index=index
    }
    public static func available() throws -> [NetworkAdapter] {
        var raw=[ch_adapter](repeating:ch_adapter(),count:128)
        var error=[CChar](repeating:0,count:256)
        let count=ch_list_adapters(&raw,Int32(raw.count),&error,error.count)
        guard count>=0 else { throw CHError.network(String(cString:error)) }
        func string<T>(_ value: T) -> String {
            withUnsafeBytes(of:value) { String(decoding:$0.prefix(while:{$0 != 0}),as:UTF8.self) }
        }
        return raw.prefix(Int(count)).map {
            NetworkAdapter(name:string($0.name),ip:string($0.address),netmask:string($0.netmask),
                           mac:withUnsafeBytes(of:$0.mac) { Wire.macText(Array($0)) },index:$0.index)
        }.sorted { $0.name == $1.name ? $0.ip < $1.ip : $0.name < $1.name }
    }
}

public final class CancellationToken: @unchecked Sendable {
    private let lock=NSLock()
    private var value=false
    public init() {}
    public func cancel() { lock.lock(); value=true; lock.unlock() }
    public func check() throws {
        lock.lock(); let v=value; lock.unlock()
        if v { throw CHError.cancelled }
    }
}

public struct WriteResult: Sendable {
    public let acknowledged: Bool
    public let readback: DeviceConfiguration?
    public let differences: [String]
    public var verified: Bool { readback != nil && differences.isEmpty }
}
public struct ResetResult: Sendable {
    public let acknowledged: Bool
    public let readback: DeviceConfiguration?
}

/// Single-owner, synchronous UDP transport. Run on a worker queue, never the UI thread.
/// No raw sockets, root access, ARP injection, packet capture, or serial cable required.
public final class UDPTransport {
    public let adapter: NetworkAdapter
    private let fd: Int32
    private let devicePort: UInt16
    private let destination: String
    private let token: CancellationToken
    private let log: (String)->Void
    private let trace: (String)->Void
    public var localPort: UInt16 { ch_udp_local_port(fd) }
    private var now: Double { ProcessInfo.processInfo.systemUptime }

    public init(adapter: NetworkAdapter, hostPort: UInt16 = Wire.hostPort,
                devicePort: UInt16 = Wire.devicePort, destination: String = "255.255.255.255",
                token: CancellationToken = CancellationToken(),
                log: @escaping (String)->Void = {_ in}, trace: @escaping (String)->Void = {_ in}) throws {
        self.adapter=adapter; self.devicePort=devicePort; self.destination=destination
        self.token=token; self.log=log; self.trace=trace
        _ = try Wire.macBytes(adapter.mac); _ = try Wire.ipv4(adapter.ip)
        var error=[CChar](repeating:0,count:256)
        let socket=ch_udp_open(adapter.index,hostPort,&error,error.count)
        guard socket>=0 else {
            throw CHError.network("無法開啟 UDP \(hostPort)：\(String(cString:error))。請關閉其他設定工具，確認網卡及區域網路權限。")
        }
        fd=socket
    }
    deinit { ch_udp_close(fd) }
    private func flush() {
        var b=[UInt8](repeating:0,count:1024), err=[CChar](repeating:0,count:256), ip=[CChar](repeating:0,count:16)
        var port: UInt16=0
        for _ in 0..<64 {
            if ch_udp_receive(fd,adapter.index,&b,b.count,0,&port,&ip,&err,err.count)<=0 { break }
        }
    }
    private func send(_ command: Command, mac: String? = nil, payload: [UInt8]? = nil) throws {
        try token.check()
        let bytes=try Wire.request(command,mac:mac,hostMAC:adapter.mac,payload:payload)
        var error=[CChar](repeating:0,count:256)
        let result=bytes.withUnsafeBufferPointer {
            ch_udp_send(fd,adapter.index,adapter.ip,destination,devicePort,$0.baseAddress,$0.count,&error,error.count)
        }
        guard result>=0 else { throw CHError.network(String(cString:error)) }
        log(String(format:"TX 0x%02X → %@:%d  MAC %@",command.rawValue,destination,devicePort,mac ?? "搜尋"))
        trace("TX " + bytes.map { String(format:"%02X",$0) }.joined(separator:" "))
    }
    private func receive(until deadline: Double) throws -> Packet? {
        while now < deadline {
            try token.check()
            var b=[UInt8](repeating:0,count:1024), error=[CChar](repeating:0,count:256), ip=[CChar](repeating:0,count:16)
            var port: UInt16=0
            let timeout=Int32(max(1,min(100,(deadline-now)*1000)))
            let n=ch_udp_receive(fd,adapter.index,&b,b.count,timeout,&port,&ip,&error,error.count)
            guard n>=0 else { throw CHError.network(String(cString:error)) }
            guard n>0, port==devicePort else { continue }
            guard let p=try? Packet(Array(b.prefix(Int(n)))), p.command>=0x80 else { continue }
            guard p.hostMAC == adapter.mac.uppercased() || p.hostMAC == "00:00:00:00:00:00" else { continue }
            log(String(format:"RX 0x%02X ← %@:%d  MAC %@",p.command,String(cString:ip),port,p.mac))
            trace("RX " + p.bytes.map { String(format:"%02X",$0) }.joined(separator:" "))
            return p
        }
        return nil
    }
    private func wait(_ expected: Command, mac: String, deadline: Double) throws -> Packet {
        while let packet=try receive(until:deadline) {
            guard packet.mac == mac.uppercased() else { continue }
            if packet.command == expected.rawValue { return packet }
            let nak: UInt8? = expected == .setACK ? 0xC1 : expected == .getACK ? 0xC2 : nil
            if packet.command == nak {
                throw CHError.network(String(format:"裝置拒絕命令，回應 0x%02X；未將此視為成功。",packet.command))
            }
        }
        throw CHError.timeout
    }
    public func discover(duration: Double = 2.4) throws -> [DeviceSummary] {
        flush()
        var found: [String:DeviceSummary]=[:]
        let started=now, deadline=started+max(0.2,duration)
        var next=started, sends=0
        while now<deadline {
            try token.check()
            if sends<3 && now>=next {
                try send(.search); sends+=1; next=started+Double(sends)*duration/3
            }
            if let p=try receive(until:min(deadline,now+0.12)), let d=try? p.discovery() {
                found[d.mac]=d
            }
        }
        return found.values.sorted { $0.mac < $1.mac }
    }
    public func readConfiguration(mac: String, timeout: Double = 2.1) throws -> DeviceConfiguration {
        flush()
        let deadline=now+timeout
        for _ in 0..<3 {
            try send(.get,mac:mac)
            do {
                return try wait(.getACK,mac:mac,deadline:min(deadline,now+timeout/3)).configuration()
            } catch CHError.timeout {
                if now>=deadline { break }
            }
        }
        throw CHError.timeout
    }
    public func configure(baseline: DeviceConfiguration, draft: DeviceConfiguration,
                          verificationSeconds: Double = 9) throws -> WriteResult {
        guard baseline.mac == draft.mac else { throw CHError.invalid("寫入目標與已讀取裝置不一致。") }
        try draft.validate()
        let fresh=try readConfiguration(mac:baseline.mac)
        guard fresh.differences(from:baseline,ignoreDynamicAddress:true).isEmpty else {
            throw CHError.invalid("裝置設定已在讀取後發生變更。為避免覆蓋其他工具的設定，請重新讀取再修改。")
        }
        var intended=fresh
        intended.copyEditableSettings(from:draft)
        let payload=try intended.encodedPayload()
        flush()
        // A flash-writing SET is sent ONCE. Lost acknowledgements must not cause repeated writes.
        try send(.set,mac:baseline.mac,payload:payload)
        var acknowledged=false
        do { _ = try wait(.setACK,mac:baseline.mac,deadline:now+2); acknowledged=true }
        catch CHError.timeout { log("未收到寫入 ACK；不重送寫入，改以讀回設定確認。") }
        catch { throw CHError.network("寫入封包已送出，裝置狀態尚未確認：\(error.localizedDescription)。請重新讀取，不要直接重複寫入。") }
        let deadline=now+max(0,verificationSeconds)
        var readback: DeviceConfiguration?
        var differences=[String]()
        while now<deadline {
            try token.check()
            Thread.sleep(forTimeInterval:0.6)
            do {
                let c=try readConfiguration(mac:baseline.mac,timeout:0.75)
                readback=c; differences=c.differences(from:intended,ignoreDynamicAddress:true)
                if differences.isEmpty { return WriteResult(acknowledged:acknowledged,readback:c,differences:[]) }
            } catch CHError.cancelled { throw CHError.cancelled }
            catch { log("重啟後讀回尚未完成：\(error.localizedDescription)") }
        }
        return WriteResult(acknowledged:acknowledged,readback:readback,differences:differences)
    }
    public func factoryReset(mac: String) throws -> ResetResult {
        flush()
        try send(.factoryReset,mac:mac)
        var acknowledged=false
        do { _ = try wait(.resetACK,mac:mac,deadline:now+2); acknowledged=true }
        catch CHError.timeout { log("未收到還原 ACK；不重送還原命令。") }
        catch { throw CHError.network("還原封包已送出，但結果未確認：\(error.localizedDescription)") }
        for _ in 0..<6 {
            try token.check(); Thread.sleep(forTimeInterval:0.6)
            if let config=try? readConfiguration(mac:mac,timeout:0.75) {
                return ResetResult(acknowledged:acknowledged,readback:config)
            }
        }
        return ResetResult(acknowledged:acknowledged,readback:nil)
    }
}
