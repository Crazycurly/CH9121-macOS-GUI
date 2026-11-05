import XCTest
import Foundation
import CNet
@testable import CH9121Core

/// Real loopback UDP peer; no physical module, LAN broadcasts, or privileged sockets.
private final class FakeModule: @unchecked Sendable {
    let fd: Int32
    let port: UInt16
    private let lock=NSLock()
    private let finished=DispatchSemaphore(value:0)
    private var stopped=false
    private var state=DeviceConfiguration.demo()
    private var writes=0
    private var resets=0
    private let dropSetACK: Bool
    private let discardSet: Bool
    private let wrongMACFirst: Bool
    private let rejectRead: Bool
    init(dropSetACK: Bool = false, discardSet: Bool = false, wrongMACFirst: Bool = false,
         rejectRead: Bool = false) throws {
        self.dropSetACK=dropSetACK; self.discardSet=discardSet
        self.wrongMACFirst=wrongMACFirst; self.rejectRead=rejectRead
        var error=[CChar](repeating:0,count:256)
        fd=ch_udp_open(0,0,&error,error.count)
        guard fd>=0 else { throw CHError.network(String(cString:error)) }
        port=ch_udp_local_port(fd)
        DispatchQueue(label:"ch9121.test.fake").async { [self] in run(); finished.signal() }
    }
    func stop() {
        lock.lock(); stopped=true; lock.unlock()
        _ = finished.wait(timeout:.now()+2)
        ch_udp_close(fd)
    }
    var setCount: Int { lock.lock(); defer { lock.unlock() }; return writes }
    var resetCount: Int { lock.lock(); defer { lock.unlock() }; return resets }
    var configuration: DeviceConfiguration { lock.lock(); defer { lock.unlock() }; return state }
    func changeBaud(_ baud: Int) { lock.lock(); state.port1.baud=baud; lock.unlock() }
    private func run() {
        while true {
            lock.lock(); let exit=stopped; lock.unlock(); if exit { break }
            var bytes=[UInt8](repeating:0,count:1024), error=[CChar](repeating:0,count:256), source=[CChar](repeating:0,count:16)
            var sourcePort: UInt16=0
            let n=ch_udp_receive(fd,0,&bytes,bytes.count,50,&sourcePort,&source,&error,error.count)
            guard n>0, let request=try? Packet(Array(bytes.prefix(Int(n)))) else { continue }
            let command=request.command
            guard command==4 || request.mac==configuration.mac else { continue }
            if command==1 {
                lock.lock(); writes+=1
                if !discardSet, let next=try? DeviceConfiguration(payload:request.data) { state=next }
                lock.unlock()
                if dropSetACK { continue }
            }
            if command==3 { lock.lock(); resets+=1; state=DeviceConfiguration.demo(); lock.unlock() }
            let c=configuration
            var response=[UInt8](repeating:0,count:285)
            response.replaceSubrange(0..<16,with:Array("CH9121_CFG_FLAG\0".utf8))
            response[16]=command | 0x80
            response.replaceSubrange(17..<23,with:try! Wire.macBytes(c.mac))
            response.replaceSubrange(23..<29,with:Array(request.bytes[23..<29]))
            if command==4 {
                let data=(try! Wire.ipv4(c.ip))+Array(c.name.utf8)+[0]
                response[29]=UInt8(data.count)
                response.replaceSubrange(30..<(30+data.count),with:data)
                response[30+data.count]=34
            } else if command==2 {
                if rejectRead { response[16]=0xC2 }
                else { response[29]=204; response.replaceSubrange(30..<285,with:try! c.encodedPayload()) }
            }
            func send(_ b: [UInt8]) {
                _ = b.withUnsafeBufferPointer {
                    ch_udp_send(fd,0,"127.0.0.1","127.0.0.1",sourcePort,$0.baseAddress,$0.count,&error,error.count)
                }
            }
            if wrongMACFirst && command==2 {
                var wrong=response; wrong[22] ^= 1
                send(wrong)
                var foreignHost=response; foreignHost[28] ^= 1
                send(foreignHost)
            }
            send(response)
        }
    }
}

final class TransportTests: XCTestCase {
    private let adapter=NetworkAdapter(name:"loopback-test",ip:"127.0.0.1",netmask:"255.0.0.0",mac:"02:00:00:00:00:02",index:0)
    private func client(_ fake: FakeModule, token: CancellationToken = CancellationToken()) throws -> UDPTransport {
        try UDPTransport(adapter:adapter,hostPort:0,devicePort:fake.port,destination:"127.0.0.1",token:token)
    }
    func testLoopbackDiscoveryDeduplicatesRepeatedReplies() throws {
        let fake=try FakeModule(); defer { fake.stop() }
        let devices=try client(fake).discover(duration:0.3)
        XCTAssertEqual(devices.count,1); XCTAssertEqual(devices.first?.mac,fake.configuration.mac)
    }
    func testLoopbackReadIgnoresWrongModuleAndHostMAC() throws {
        let fake=try FakeModule(wrongMACFirst:true); defer { fake.stop() }
        let c=try client(fake).readConfiguration(mac:fake.configuration.mac,timeout:0.6)
        XCTAssertEqual(c.mac,fake.configuration.mac); XCTAssertEqual(c.port1.baud,9600)
    }
    func testWriteGetsACKAndSeparatelyVerifiesReadback() throws {
        let fake=try FakeModule(); defer { fake.stop() }
        let c=try client(fake), baseline=fake.configuration
        var next=baseline; try next.applyLidarPreset("M10P",receiverIP:"192.168.1.102")
        let result=try c.configure(baseline:baseline,draft:next,verificationSeconds:2)
        XCTAssertTrue(result.acknowledged); XCTAssertTrue(result.verified)
        XCTAssertEqual(result.readback?.port1.baud,512000); XCTAssertEqual(fake.setCount,1)
    }
    func testLostACKDoesNotResendFlashWriteAndStillVerifies() throws {
        let fake=try FakeModule(dropSetACK:true); defer { fake.stop() }
        let c=try client(fake), baseline=fake.configuration
        var next=baseline; next.port1.baud=512000
        let result=try c.configure(baseline:baseline,draft:next,verificationSeconds:2)
        XCTAssertFalse(result.acknowledged); XCTAssertTrue(result.verified)
        XCTAssertEqual(fake.setCount,1)
    }
    func testACKAloneIsNotWriteSuccess() throws {
        let fake=try FakeModule(discardSet:true); defer { fake.stop() }
        let c=try client(fake), baseline=fake.configuration
        var next=baseline; next.port1.baud=512000
        let result=try c.configure(baseline:baseline,draft:next,verificationSeconds:0.1)
        XCTAssertTrue(result.acknowledged); XCTAssertFalse(result.verified)
        XCTAssertFalse(result.differences.isEmpty); XCTAssertEqual(fake.setCount,1)
    }
    func testStaleBaselinePreventsWrite() throws {
        let fake=try FakeModule(); defer { fake.stop() }
        let c=try client(fake), baseline=fake.configuration
        var next=baseline; next.port1.baud=512000
        fake.changeBaud(115200)
        XCTAssertThrowsError(try c.configure(baseline:baseline,draft:next))
        XCTAssertEqual(fake.setCount,0)
    }
    func testReadNAKIsNotAcceptedAsConfiguration() throws {
        let fake=try FakeModule(rejectRead:true); defer { fake.stop() }
        XCTAssertThrowsError(try client(fake).readConfiguration(mac:fake.configuration.mac,timeout:0.3))
    }
    func testResetSentOnceAndReadbackReturnedSeparately() throws {
        let fake=try FakeModule(); defer { fake.stop() }; fake.changeBaud(512000)
        let result=try client(fake).factoryReset(mac:fake.configuration.mac)
        XCTAssertTrue(result.acknowledged); XCTAssertEqual(result.readback?.port1.baud,9600)
        XCTAssertEqual(fake.resetCount,1)
    }
    func testCancellationBeforeSend() throws {
        let fake=try FakeModule(); defer { fake.stop() }
        let token=CancellationToken(); token.cancel()
        XCTAssertThrowsError(try client(fake,token:token).discover(duration:0.3))
        XCTAssertEqual(fake.setCount,0)
    }
    func testPortCannotBeSharedBySecondConfigurator() throws {
        let first=try UDPTransport(adapter:adapter,hostPort:0,destination:"127.0.0.1")
        XCTAssertGreaterThan(first.localPort,0)
        XCTAssertThrowsError(try UDPTransport(adapter:adapter,hostPort:first.localPort,destination:"127.0.0.1"))
        withExtendedLifetime(first) {}
    }
    func testReadTimeoutIsBounded() throws {
        let fake=try FakeModule(); defer { fake.stop() }
        let started=ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try client(fake).readConfiguration(mac:"02:00:00:00:00:99",timeout:0.15))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime-started,1)
    }
}
