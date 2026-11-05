#if os(macOS)
import SwiftUI
import AppKit
import CH9121Core

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.activate(ignoringOtherApps:true) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main struct CH9121ConfigApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model=AppModel(demo:CommandLine.arguments.contains("--demo"))
    init() {
        if CommandLine.arguments.contains("--smoke-test") {
            // CI launches the REAL bundled GUI without opening a network socket.
            let app=NSApplication.shared
            app.setActivationPolicy(.accessory)
            let demo=AppModel(demo:true)
            let host=NSHostingView(rootView:ContentView(model:demo)
                .background(Color(nsColor:.windowBackgroundColor))
                .preferredColorScheme(.light))
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1120,height:880),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
            window.appearance=NSAppearance(named:.aqua)
            window.contentView=host
            window.center()
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps:true)
            // SwiftUI and native AppKit controls finish drawing on later run-loop turns.
            // Capturing an unshown view immediately leaves tabs/buttons partially blank.
            RunLoop.main.run(until:Date(timeIntervalSinceNow:1.0))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            guard demo.canEdit, host.frame.width>0 else { exit(1) }
            if let i=CommandLine.arguments.firstIndex(of:"--screenshot") {
                guard i+1<CommandLine.arguments.count,
                      let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) else {
                    print("GUI screenshot initialization failed."); exit(1)
                }
                host.cacheDisplay(in:host.bounds,to:bitmap)
                guard let png=bitmap.representation(using:.png,properties:[:]) else { exit(1) }
                do { try png.write(to:URL(fileURLWithPath:CommandLine.arguments[i+1])) }
                catch { print("GUI screenshot failed: \(error)"); exit(1) }
            }
            print("Native macOS GUI smoke test passed (demo only; no network).")
            exit(0)
        }
    }
    var body: some Scene {
        WindowGroup("CH9121 Config") { ContentView(model:model) }
            .defaultSize(width:1120,height:880)
            .commands {
                CommandGroup(replacing:.newItem) {}
                CommandMenu("裝置") {
                    Button("搜尋設備",action:model.scan).keyboardShortcut("r",modifiers:.command).disabled(model.busy)
                    Button("讀取設定",action:model.readSelected).keyboardShortcut("o",modifiers:[.command,.shift]).disabled(!model.canRead)
                    Divider()
                    Button("儲存設定…",action:model.saveConfiguration).keyboardShortcut("s",modifiers:.command).disabled(!model.canEdit)
                    Button("載入設定…",action:model.loadConfiguration).disabled(!model.canEdit)
                    Button("顯示最近的自動備份",action:model.revealBackup).disabled(model.lastBackup.isEmpty)
                    Divider()
                    Button("匯出通訊紀錄…",action:model.exportLogs)
                }
            }
    }
}
#else
import Foundation
import CH9121Core
@main struct UnsupportedPlatform {
    static func main() {
        print("CH9121 Config 的 GUI 需要 macOS 13 或更新版本。協定與 UDP 測試可在 Linux 上執行：swift test")
    }
}
#endif
