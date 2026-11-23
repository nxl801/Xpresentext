//
//  TextreamApp.swift
//  Textream
//
//  Created by Fatih Kadir Akın on 8.02.2026.
//

import SwiftUI
import OSLog

extension Notification.Name {
    static let openSettings = Notification.Name("openSettings")
    static let openAbout = Notification.Name("openAbout")
    static let startPrompter = Notification.Name("startPrompter")
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let lifecycleLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.fka.textream",
        category: "AppLifecycle"
    )

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        let launchedByURL: Bool
        if let event = NSAppleEventManager.shared().currentAppleEvent {
            launchedByURL = event.eventClass == kInternetEventClass
        } else {
            launchedByURL = false
        }
        if launchedByURL {
            TextreamService.shared.launchedExternally = true
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = TextreamService.shared
        NSUpdateDynamicServices()

        if TextreamService.shared.launchedExternally {
            TextreamService.shared.hideMainWindow()
        }


        // Start browser server if enabled
        TextreamService.shared.updateBrowserServer()

        // Start director server if enabled
        TextreamService.shared.updateDirectorServer()

        // Set window delegate to intercept close, disable tabs and fullscreen
        DispatchQueue.main.async {
            for window in NSApp.windows where !(window is NSPanel) {
                window.delegate = self
                window.tabbingMode = .disallowed
                window.collectionBehavior.remove(.fullScreenPrimary)
                window.collectionBehavior.insert(.fullScreenNone)
            }
            self.removeUnwantedMenus()
        }
    }

    private func removeUnwantedMenus() {
        guard let mainMenu = NSApp.mainMenu else { return }
        // Remove View and Window menus (keep Edit for copy/paste)
        let menusToRemove = ["View", "Window"]
        for title in menusToRemove {
            if let index = mainMenu.items.firstIndex(where: { $0.title == title }) {
                mainMenu.removeItem(at: index)
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if TextreamService.shared.hasUnsavedChanges {
            guard TextreamService.shared.confirmDiscardIfNeeded() else { return false }
        }
        NSApp.terminate(nil)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if StudioWorkspace.shared.saving {
            Task { @MainActor in
                let saved = await StudioWorkspace.shared.flushSave()
                sender.reply(toApplicationShouldTerminate: saved)
            }
            return .terminateLater
        }
        if StudioWorkspace.shared.hasSaveFailure {
            StudioWorkspace.shared.saveNow()
            Task { @MainActor in
                sender.reply(toApplicationShouldTerminate: await StudioWorkspace.shared.flushSave())
            }
            return .terminateLater
        }
        guard
            TextreamService.shared.overlayController.isShowing,
            let event = NSAppleEventManager.shared().currentAppleEvent,
            event.eventClass == kCoreEventClass,
            event.eventID == kAEQuitApplication,
            event.paramDescriptor(forKeyword: kAEQuitReason) == nil
        else {
            return .terminateNow
        }

        let senderPID = event.attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value ?? 0
        let runningApplication = NSRunningApplication(processIdentifier: pid_t(senderPID))
        let senderName = runningApplication?.localizedName ?? "unknown"
        let senderBundleIdentifier = runningApplication?.bundleIdentifier ?? "unknown"

        lifecycleLogger.warning(
            "Blocked external quit while teleprompter is active; senderPID=\(senderPID, privacy: .public) sender=\(senderName, privacy: .public) bundleIdentifier=\(senderBundleIdentifier, privacy: .public)"
        )
        return .terminateCancel
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if TextreamService.shared.launchedExternally {
            TextreamService.shared.launchedExternally = false
            NSApp.setActivationPolicy(.regular)
        }
        if !flag {
            // Show existing window instead of letting SwiftUI create a duplicate
            for window in NSApp.windows where !(window is NSPanel) {
                window.makeKeyAndOrderFront(nil)
                return false
            }
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.isFileURL && ["textream", "pptx"].contains(url.pathExtension.lowercased()) {
                StudioWorkspace.shared.openURL(url)
                for window in NSApp.windows where !(window is NSPanel) {
                    window.makeKeyAndOrderFront(nil)
                }
                NSApp.activate(ignoringOtherApps: true)
            } else {
                let wasExternal = TextreamService.shared.launchedExternally
                TextreamService.shared.launchedExternally = true
                if !wasExternal {
                    NSApp.setActivationPolicy(.accessory)
                }
                TextreamService.shared.hideMainWindow()
                TextreamService.shared.handleURL(url)
            }
        }
    }
}

#if !COMPANION_ACCEPTANCE
@main
#endif
struct TextreamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var workspace = StudioWorkspace.shared

    var body: some Scene {
        WindowGroup("Xpresentext") {
            StudioRoot(StudioWorkspace.shared)
                .onOpenURL { url in
                    if url.isFileURL {
                        StudioWorkspace.shared.openURL(url)
                    } else {
                        TextreamService.shared.handleURL(url)
                    }
                }
        }
        .defaultSize(width: 1100, height: 740)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Xpresentext") {
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
            }
            CommandGroup(after: .appSettings) {
                Button("Settings…") {
                    if StudioWorkspace.shared.classic {
                        NotificationCenter.default.post(name: .openSettings, object: nil)
                    } else {
                        StudioWorkspace.shared.settingsVisible = true
                    }
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button("Open File or Presentation…") {
                    StudioWorkspace.shared.chooseFile()
                }
                .keyboardShortcut("o", modifiers: .command)

                Divider()

                Button("Save") {
                    if StudioWorkspace.shared.classic { TextreamService.shared.saveFile() }
                    else { StudioWorkspace.shared.saveNow() }
                }
                .keyboardShortcut("s", modifiers: .command)

                if workspace.classic {
                    Button("Save As…") { TextreamService.shared.saveFileAs() }
                        .keyboardShortcut("s", modifiers: [.command, .shift])
                }

                Divider()

                Button("Start Prompter") {
                    if StudioWorkspace.shared.classic {
                        NotificationCenter.default.post(name: .startPrompter, object: nil)
                    } else { StudioWorkspace.shared.tracking.startFollowing() }
                }
                .keyboardShortcut(.return, modifiers: .command)
            }
            CommandGroup(replacing: .windowArrangement) { }
            CommandGroup(replacing: .help) {
                Button("Xpresentext Help") {
                    if let url = Bundle.main.url(forResource: "README", withExtension: "md") ?? URL(string: "https://github.com/nxl801/Xpresentext") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}
