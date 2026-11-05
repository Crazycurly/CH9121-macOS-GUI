# Protocol implementation notes

Scope: legacy CH9121 base network configuration, not CH9121A/T extended commands. Independently implemented in Swift/C. No vendor executable is shipped.

## Evidence

- User-provided `串口改网口模块设置说明.docx`, pages 2–5: required GUI controls, M10P settings and post-write reboot. Not redistributed in this repository.
- WCH official download entry: https://www.wch.cn/downloads/CH9121EVT_ZIP.html . A link to the vendor package, not a claim of vendor approval of this implementation.
- Published C field descriptions and original packet traces: https://www.cnblogs.com/Lqqq123/p/17954976 . The literal SEARCH/GET trace is an independent test fixture. This is a public technical article, not a conformance certificate or a trace captured from the user's module.
- Upstream implementation inspected for comparison: https://github.com/CursedHardware/ch912x , specifically `constants.go`, `ch9121.go`, `control_plane.go`. It was not imported as a dependency or copied wholesale.
- Official CI/CLI behavior: https://docs.github.com/en/actions/reference/runners/github-hosted-runners and https://cli.github.com/manual/gh_repo_create . Runner labels were checked 2026-11-05.

## Packet and addressing

All requests are 285 bytes. Header: magic `CH9121_CFG_FLAG` NUL-padded to 16 bytes, command at 16, target MAC at 17, PC MAC at 23, data length at 29, payload at 30. UDP host port 60000, device port 50000, limited broadcast on the selected NIC.

Commands: SET `01`, GET `02`, FACTORY RESET `03`, SEARCH `04`; matching ACKs `81..84`. SET/GET rejection `C1/C2` is not success. SET data length is `CC` (204). Discovery carries IP, a NUL-terminated name, then firmware version. Configuration is 74 bytes hardware + two 65-byte port records; UART2 is first, UART1 second. The remainder is preserved if returned.

Hardware offsets: identity `0..4` (read-only), name `5..25`, MAC `26..31` (read-only), IP `32`, gateway `36`, mask `40`, DHCP `44`, serial configuration flag `65`. Unlisted bytes are not reinterpreted or zeroed.

Port-relative offsets:

| Offset | Size | Meaning |
|---:|---:|---|
| 0 | 1 | Index; read-only |
| 1 / 2 / 3 | 1 each | Enable / network mode / random local port |
| 4 | 2 | Local port, LE |
| 6 | 4 | Destination IPv4 |
| 10 | 2 | Destination port, LE |
| 12 | 4 | Baud, LE |
| 16 / 17 / 18 / 19 | 1 each | Data bits / stop bits / parity / close on disconnect |
| 20 / 24 | 4 each | RX packet length / RX timeout, LE |
| 28 | 1 | Preserved |
| 29 / 30 | 1 each | Clear buffer / domain flag |
| 31 | 20 | Domain bytes |
| 51 | 14 | Preserved |

Mode values 0/1/2/3 map to TCP Server/TCP Client/UDP Server/UDP Client. Parity wire values 0/1/2/3/4 map to Odd/Even/Mark/Space/None. Serial settings are not encoded as display-list indices.

## Disagreements and conservative choices

The public C comment says stop bit 0 means one, while the packet example's annotation says 1 means one. The shipped manual shows one stop bit and the inspected Go library treats this byte literally. This version uses the trace mapping 1/2 and rejects unknown values; **hardware verification is required**. It does not silently reinterpret 0.

The inspected Go writer maps no-parity to 0 despite its reader recognizing 4. Its labels for local/destination ports and its RX 16-bit layout also disagree with the public 32-bit field definitions. This project uses the packet trace and field definitions, with tests for byte offsets and 512000 baud. It does not wrap that writer.

RX timeout is displayed as raw numeric data because sources distinguish old 10-ms units from newer 5-ms units. The GUI does not convert between them or infer chipset generation from a name.

Boolean decoding treats 1 as enabled. Unchanged non-1 values are preserved, rather than normalized. Names are decoded as UTF-8 with a Latin-1 display fallback; unchanged raw bytes survive, but editing a name writes UTF-8. Non-ASCII interoperability is not verified.

Only GET ACK with length exactly 204 can become an editable configuration. Unknown sizes and malformed packets are rejected. A short valid payload is padded only after the 204-byte interpreted portion; absent trailing bytes are treated as padding. No unknown field is exposed as a writable zero-filled default.

## Transactions

GET may retry. SET and factory reset do not retry. Before SET, a fresh GET guards against stale editable parameters; intended edits are applied to that fresh payload. Fresh reserved bytes and identity are retained. A missing SET ACK leads to GET polling, never a second flash write. A SET ACK by itself does not yield a green success state.

Independent GET readback verifies editable fields; IP/mask/gateway lease changes are ignored only when both configurations use DHCP. Factory reset returns ACK presence and readback separately; it does not assert that vendor defaults were fully verified.

Ports are exclusively bound; no raw socket, ARP injection, promiscuous capture or elevated privilege is needed by this implementation. macOS selects the NIC using `IP_BOUND_IF`; Linux tests use `IP_PKTINFO` for interface filtering. There is no claim that these checks cryptographically authenticate a device.

Backups use this program's own JSON envelope containing payload bytes, source MAC, format version and creation timestamp. Vendor `.cfg` compatibility is explicitly not provided.
