import XCTest
@testable import CH9121Core

// Independent literal fixture transcribed from the public GET packet trace.
// Source and interpretation disagreements are documented in docs/PROTOCOL.md.
private func hex(_ s: String) -> [UInt8] {
    s.split(whereSeparator: { $0.isWhitespace }).map { UInt8($0, radix:16)! }
}
func publishedConfigurationResponse() -> [UInt8] {
    let header=hex("43 48 39 31 32 31 5f 43 46 47 5f 46 4c 41 47 00 82 38 3b 26 44 de a5 00 00 00 00 00 00 cc")
    let hardware=hex("""
    21 21 01 02 06
    43 48 39 31 32 31 20 00 00 00 00 00 00 00 00 00 00 00 00 00 00
    38 3b 26 44 de a5 c0 a8 01 02 c0 a8 01 01 ff ff ff 00 00
    50 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 ff 00
    00 00 00 00 00 00 00 00
    """)
    let auxiliary=hex("""
    00 00 02 01 b8 0b c0 a8 01 64 d0 07 80 25 00 00 08 01 04 01
    00 04 00 00 00 00 00 00 00 00 00
    00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
    00 00 00 00 00 00 00 00 00 00 00 00 00 00
    """)
    let primary=hex("""
    01 01 00 01 64 09 c0 a8 01 64 e8 03 00 e1 00 00 08 01 04 01
    00 04 00 00 00 00 00 00 00 00 00
    00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
    00 00 00 00 00 00 00 00 00 00 00 00 00 00
    """)
    precondition(header.count==30 && hardware.count==74 && auxiliary.count==65 && primary.count==65)
    return header+hardware+auxiliary+primary+[UInt8](repeating:0,count:51)
}

final class ProtocolTests: XCTestCase {
    func testPublishedGetTraceDecodesIndependentValues() throws {
        let c=try Packet(publishedConfigurationResponse()).configuration()
        XCTAssertEqual(c.mac,"38:3B:26:44:DE:A5")
        XCTAssertEqual(c.name,"CH9121 ")
        XCTAssertEqual(c.ip,"192.168.1.2")
        XCTAssertEqual(c.gateway,"192.168.1.1")
        XCTAssertEqual(c.netmask,"255.255.255.0")
        XCTAssertTrue(c.port1.enabled); XCTAssertFalse(c.port2.enabled)
        XCTAssertEqual(c.port1.mode,0); XCTAssertEqual(c.port2.mode,2)
        XCTAssertEqual(c.port1.localPort,2404); XCTAssertEqual(c.port1.destinationPort,1000)
        XCTAssertEqual(c.port2.localPort,3000); XCTAssertEqual(c.port2.destinationPort,2000)
        XCTAssertEqual(c.port1.baud,57600); XCTAssertEqual(c.port2.baud,9600)
        XCTAssertEqual(c.port1.parity,4); XCTAssertEqual(c.port1.stopBits,1)
        XCTAssertEqual(c.port1.packetLength,1024); XCTAssertEqual(c.port1.packetTimeout,0)
        XCTAssertEqual(try c.encodedPayload(),Array(publishedConfigurationResponse().dropFirst(30)))
    }
    func testSearchRequestMatchesPublishedHeader() throws {
        let b=try Wire.request(.search,hostMAC:"02:00:00:00:00:02")
        XCTAssertEqual(b.count,285)
        XCTAssertEqual(Array(b.prefix(17)),hex("43 48 39 31 32 31 5f 43 46 47 5f 46 4c 41 47 00 04"))
        XCTAssertTrue(b.dropFirst(17).allSatisfy { $0 == 0 })
    }
    func testPublishedSearchResponse() throws {
        let b=hex("43 48 39 31 32 31 5f 43 46 47 5f 46 4c 41 47 00 84 38 3b 26 44 de a5 00 00 00 00 00 00 0c c0 a8 01 02 43 48 39 31 32 31 20 00 29")
        let d=try Packet(b).discovery()
        XCTAssertEqual(d.name,"CH9121 "); XCTAssertEqual(d.version,41)
        XCTAssertEqual(d.ip,"192.168.1.2"); XCTAssertEqual(d.mac,"38:3B:26:44:DE:A5")
    }
    func testMalformedPacketsAreRejectedWithoutCrashing() throws {
        let good=publishedConfigurationResponse()
        for count in 0..<30 { XCTAssertThrowsError(try Packet(Array(good.prefix(count)))) }
        for count in 30..<234 { XCTAssertThrowsError(try Packet(Array(good.prefix(count))).configuration()) }
        var wrongMagic=good; wrongMagic[0]=0; XCTAssertThrowsError(try Packet(wrongMagic))
        XCTAssertThrowsError(try Packet(good+[0]))
        var wrongLength=good; wrongLength[29]=205
        XCTAssertThrowsError(try Packet(wrongLength).configuration())
        var wrongMAC=good; wrongMAC[17]=2
        XCTAssertThrowsError(try Packet(wrongMAC).configuration())
    }
    func testDiscoveryLengthAndNameBounds() throws {
        var b=try Wire.request(.search); b[16]=0x84
        for length:UInt8 in [0,4,26,255] {
            b[29]=length; XCTAssertThrowsError(try Packet(b).discovery())
        }
        b[29]=5; b[34]=65; XCTAssertThrowsError(try Packet(b).discovery())
        b[34]=0; XCTAssertNoThrow(try Packet(b).discovery())
    }
    func testMACAndIPParsing() throws {
        XCTAssertEqual(try Wire.macBytes("02-00-01-02-ab-CD"),[2,0,1,2,171,205])
        for mac in ["00:1:02:03:04:05","","02:03:04:05:06:GG"] { XCTAssertThrowsError(try Wire.macBytes(mac)) }
        for ip in ["1.2.3","1.2.3.256","-1.2.3.4","1.2.3.4 ","１.2.3.4","1..2.3"] { XCTAssertThrowsError(try Wire.ipv4(ip)) }
        XCTAssertEqual(try Wire.ipv4("192.168.1.200"),[192,168,1,200])
    }
    func testRejectUnsafeRequestTargetsAndResponseCommands() throws {
        for mac in ["00:00:00:00:00:00","FF:FF:FF:FF:FF:FF","01:00:5E:00:00:01"] {
            XCTAssertThrowsError(try Wire.request(.factoryReset,mac:mac))
        }
        XCTAssertThrowsError(try Wire.request(.get))
        XCTAssertThrowsError(try Wire.request(.getACK))
        XCTAssertThrowsError(try Wire.request(.set,mac:DeviceConfiguration.demo().mac,payload:[1]))
        XCTAssertThrowsError(try Wire.request(.get,mac:DeviceConfiguration.demo().mac,payload:[1]))
    }
    func testM10PPresetExactBytesAndCorrectPortOrder() throws {
        var c=DeviceConfiguration.demo(); let before=c.originalPayload
        try c.applyLidarPreset("M10P",receiverIP:"192.168.1.102")
        let b=try c.encodedPayload()
        XCTAssertEqual(Array(b[74..<139]),Array(before[74..<139]))
        XCTAssertEqual(Array(b[0..<74]),Array(before[0..<74]))
        XCTAssertEqual(b[141],3)
        XCTAssertEqual(Array(b[143..<145]),[0x41,0x09]) // local 2369
        XCTAssertEqual(Array(b[149..<151]),[0x40,0x09]) // remote 2368
        XCTAssertEqual(Array(b[151..<155]),[0x00,0xD0,0x07,0x00]) // 512000 LE
        XCTAssertEqual(Array(b[155..<158]),[8,1,4]) // 8N1, parity none == 4
        let packet=try Wire.request(.set,mac:c.mac,hostMAC:"02:00:00:00:00:02",payload:b)
        XCTAssertEqual(packet.count,285); XCTAssertEqual(packet[29],204)
        XCTAssertEqual(Array(packet[17..<23]),try Wire.macBytes(c.mac))
        XCTAssertEqual(Array(packet.dropFirst(30)),b)
    }
    func testAllLidarBaudPresets() throws {
        for (name,baud) in [("M10",460800),("M10P",512000),("N10",230400),("N10P",460800)] {
            var c=DeviceConfiguration.demo(); try c.applyLidarPreset(name,receiverIP:"192.168.1.102")
            XCTAssertEqual(c.port1.baud,baud); XCTAssertNoThrow(try c.validate())
        }
        var c=DeviceConfiguration.demo()
        XCTAssertThrowsError(try c.applyLidarPreset("unknown",receiverIP:"192.168.1.1"))
    }
    func testReservedBytesSurviveKnownFieldChange() throws {
        var original=DeviceConfiguration.demo().originalPayload
        let reserved=Array(45..<65)+Array(66..<74)+[74,102,139,167]+Array(125..<139)+Array(190..<255)
        for i in reserved { original[i]=UInt8(truncatingIfNeeded:i*13+17) }
        var c=try DeviceConfiguration(payload:original); c.port1.baud=512000
        let after=try c.encodedPayload()
        for i in 0..<255 where !(151..<155).contains(i) { XCTAssertEqual(after[i],original[i],"byte \(i)") }
    }
    func testRXLengthAndTimeoutAreUInt32NotAdjacentUInt16() throws {
        var bytes=DeviceConfiguration.demo().originalPayload
        bytes.replaceSubrange(159..<163,with:[0,4,0,0]); bytes.replaceSubrange(163..<167,with:[200,0,0,0])
        var c=try DeviceConfiguration(payload:bytes)
        XCTAssertEqual(c.port1.packetLength,1024); XCTAssertEqual(c.port1.packetTimeout,200)
        c.port1.packetLength=500; c.port1.packetTimeout=7
        let out=try c.encodedPayload()
        XCTAssertEqual(Array(out[159..<167]),[244,1,0,0,7,0,0,0])
    }
    func testUnknownFlagEncodingPreservedWhenUnchanged() throws {
        var b=DeviceConfiguration.demo().originalPayload
        b[169]=2 // useDomain false, variant encoding
        var c=try DeviceConfiguration(payload:b); c.port1.baud=512000
        XCTAssertFalse(c.port1.useDomain); XCTAssertEqual(try c.encodedPayload()[169],2)
        c.port1.useDomain=true; c.port1.domain="example.org"
        XCTAssertEqual(try c.encodedPayload()[169],1)
    }
    func testValidationRejectsBadSettings() throws {
        var c=DeviceConfiguration.demo()
        c.netmask="255.0.255.0"; XCTAssertThrowsError(try c.validate())
        c=DeviceConfiguration.demo(); c.ip="192.168.1.255"; XCTAssertThrowsError(try c.validate())
        c=DeviceConfiguration.demo(); c.ip="192.168.1.0"; XCTAssertThrowsError(try c.validate())
        c=DeviceConfiguration.demo(); c.name=String(repeating:"中",count:7); XCTAssertThrowsError(try c.validate())
        c=DeviceConfiguration.demo(); c.port1.parity=5; XCTAssertThrowsError(try c.validate())
        c=DeviceConfiguration.demo(); c.port1.stopBits=0; XCTAssertThrowsError(try c.validate())
        c=DeviceConfiguration.demo(); c.port1.baud=299; XCTAssertThrowsError(try c.validate())
        c=DeviceConfiguration.demo(); c.port1.localPort=65536; XCTAssertThrowsError(try c.validate())
        c=DeviceConfiguration.demo(); c.port1.packetLength=1025; XCTAssertThrowsError(try c.validate())
        c=DeviceConfiguration.demo(); c.port1.packetTimeout=201; XCTAssertThrowsError(try c.validate())
        c=DeviceConfiguration.demo(); c.port1.enabled=false; XCTAssertThrowsError(try c.validate())
    }
    func testDomainLengthAndFormat() throws {
        var c=DeviceConfiguration.demo(); c.port1.useDomain=true
        c.port1.domain="abcdefghijklmnop.com"; XCTAssertEqual(c.port1.domain.count,20)
        XCTAssertNoThrow(try c.validate())
        c.port1.domain+="x"; XCTAssertThrowsError(try c.validate())
        c.port1.domain="http://test"; XCTAssertThrowsError(try c.validate())
    }
    func testArchiveRoundTripAndRejectInvalidOrOversizedFiles() throws {
        let c=DeviceConfiguration.demo()
        let json=try ConfigurationArchive(config:c).json()
        XCTAssertEqual(try ConfigurationArchive.load(json).configuration().encodedPayload(),try c.encodedPayload())
        XCTAssertThrowsError(try ConfigurationArchive.load(Data("not JSON".utf8)))
        XCTAssertThrowsError(try ConfigurationArchive.load(Data(repeating:0,count:128*1024)))
        let text=String(decoding:json,as:UTF8.self).replacingOccurrences(of:"CH9121ConfigBackup",with:"VendorCFG")
        XCTAssertThrowsError(try ConfigurationArchive.load(Data(text.utf8)))
    }
    func testImportKeepsTargetMACFirmwareAndReservedBytes() throws {
        var target=DeviceConfiguration.demo()
        var imported=try Packet(publishedConfigurationResponse()).configuration()
        imported.port1.baud=512000
        let original=target.originalPayload
        target.copyEditableSettings(from:imported)
        let b=try target.encodedPayload()
        XCTAssertEqual(target.mac,"02:00:00:91:21:01")
        XCTAssertEqual(Array(b[0..<5]),Array(original[0..<5]))
        XCTAssertEqual(Array(b[26..<32]),Array(original[26..<32]))
        XCTAssertEqual(Array(b[45..<65]),Array(original[45..<65]))
        XCTAssertEqual(target.port1.baud,512000)
    }
    func testDHCPLeaseChangesIgnoredOnlyWhenRequested() throws {
        var a=DeviceConfiguration.demo(); a.dhcp=true
        var b=a; b.ip="192.168.1.123"
        XCTAssertEqual(b.differences(from:a).count,1)
        XCTAssertTrue(b.differences(from:a,ignoreDynamicAddress:true).isEmpty)
        b.port1.baud=512000
        XCTAssertEqual(b.differences(from:a,ignoreDynamicAddress:true).count,1)
    }
    func testDisabledPortEditsRemainVisibleInDiff() {
        let a=DeviceConfiguration.demo(); var b=a; b.port2.baud=115200
        XCTAssertEqual(b.differences(from:a).count,1)
    }
}
