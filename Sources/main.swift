import AppKit
import Carbon
import ApplicationServices
import ServiceManagement

private let appName = "Brightery Clipboard"
private let defaults = UserDefaults.standard
private let maxBytes = 1_048_576
private let pasteboard = NSPasteboard.general

final class PickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}
final class ClipButton: NSButton { var clipID: Int64 = 0 }
final class ClipTable: NSTableView {
    var onReturn: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onReturn?(); return }
        super.keyDown(with:event)
    }
}
func symbol(_ name: String, _ description: String) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: description)
}
func label(_ value: String, size: CGFloat = 13, secondary: Bool = false) -> NSTextField {
    let field = NSTextField(labelWithString: value)
    field.font = .systemFont(ofSize: size)
    field.textColor = secondary ? .secondaryLabelColor : .labelColor
    return field
}
func button(_ title: String, target: AnyObject, action: Selector) -> NSButton {
    let b = NSButton(title: title, target: target, action: action)
    b.bezelStyle = .rounded
    return b
}
func stack(_ views: [NSView], vertical: Bool = false, spacing: CGFloat = 8) -> NSStackView {
    let s = NSStackView(views: views); s.orientation = vertical ? .vertical : .horizontal
    s.alignment = vertical ? .leading : .centerY; s.spacing = spacing
    return s
}
func flexible() -> NSView { let v = NSView(); v.setContentHuggingPriority(.defaultLow, for: .horizontal); return v }

final class App: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    private var store: HistoryStore!
    private var status: NSStatusItem!
    private var timer: Timer?
    private var hotKey: EventHotKeyRef?
    private var hotHandler: EventHandlerRef?
    private var lastChange = pasteboard.changeCount
    private var lastPrune = Date.distantPast
    private var previousApp: NSRunningApplication?
    private var picker: PickerPanel!
    private var settingsWindow: NSWindow?
    private var search = NSSearchField()
    private var table = ClipTable()
    private var footer = label("", secondary: true)
    private var prev: NSButton!
    private var next: NSButton!
    private var clips: [Clip] = []
    private var page = 0
    private var searchWork: DispatchWorkItem?
    private var editing = false
    private var pasting = false
    private var paused: Bool { defaults.bool(forKey: "paused") }
    private var pageSize: Int { let n = defaults.integer(forKey: "pageSize"); return [10,20,50,100].contains(n) ? n : 20 }
    private var retention: Int { defaults.integer(forKey: "retention") }
    private let dates: DateFormatter = { let d = DateFormatter(); d.dateStyle = .medium; d.timeStyle = .short; return d }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: ["pageSize":20,"retention":0,"paused":false])
        do {
            let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            store = try HistoryStore(url: base.appendingPathComponent(appName).appendingPathComponent("history.sqlite3"))
        } catch { alert("Cannot open clipboard history", error.localizedDescription); NSApp.terminate(nil); return }
        buildPicker()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = symbol("clipboard", appName)
        status.button?.imagePosition = .imageOnly
        status.button?.toolTip = "Brightery Clipboard • ⌘⇧V"
        rebuildMenu()
        registerHotkey()
        prune()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = 0.15
        RunLoop.main.add(timer!, forMode: .common)
    }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate(); searchWork?.cancel()
        if let key = hotKey { UnregisterEventHotKey(key) }
        if let handler = hotHandler { RemoveEventHandler(handler) }
        if retention == -1 { try? store?.clear() }
    }
    private func activateSelf() {
        if #available(macOS 14.0, *) { NSApp.activate() }
        else { NSApp.activate(ignoringOtherApps: true) }
    }
    private func alert(_ message: String, _ detail: String = "") {
        let a = NSAlert(); a.messageText = message; a.informativeText = detail; a.addButton(withTitle: "OK")
        activateSelf(); a.runModal()
    }
    private func report(_ error: Error) { NSLog("Clipboard operation failed: %@", error.localizedDescription); alert("Clipboard operation failed", error.localizedDescription) }
    private func rebuildMenu() {
        let m = NSMenu()
        func item(_ title: String, _ action: Selector, _ icon: String) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: ""); i.target = self; i.image = symbol(icon,title); return i
        }
        m.addItem(item("Clipboard History     ⌘⇧V", #selector(openPicker), "clock.arrow.circlepath"))
        m.addItem(item(paused ? "Resume Recording" : "Pause Recording", #selector(togglePause), paused ? "play.circle" : "pause.circle"))
        m.addItem(.separator())
        m.addItem(item("Settings…", #selector(openSettings), "gearshape"))
        m.addItem(item("Accessibility Permission…", #selector(requestPermission), "lock.shield"))
        m.addItem(item("Clear History…", #selector(clearHistory), "trash"))
        m.addItem(.separator())
        m.addItem(item("Quit Brightery Clipboard", #selector(quit), "power"))
        status.menu = m
        status.button?.image = symbol(paused ? "pause.circle" : "clipboard", appName)
    }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func togglePause() { defaults.set(!paused, forKey: "paused"); lastChange = pasteboard.changeCount; rebuildMenu(); reload() }
    @objc private func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        alert("Enable automatic paste", "In System Settings → Privacy & Security → Accessibility, enable Brightery Clipboard. Until enabled, selecting an item copies it to the clipboard for manual ⌘V.")
    }
    private func registerHotkey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event = event, let context = context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let r = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard r == noErr, id.id == 1, id.signature == 0x42434C50 else { return OSStatus(eventNotHandledErr) }
            let app = Unmanaged<App>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { app.openPicker() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &hotHandler)
        guard result == noErr else { alert("Could not register shortcut", "Use the menu-bar icon instead."); return }
        let id = EventHotKeyID(signature: 0x42434C50, id: 1)
        let r = RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(cmdKey | shiftKey), id, GetApplicationEventTarget(), 0, &hotKey)
        if r != noErr { alert("⌘⇧V is unavailable", "Another app may already be using this shortcut. You can still open history from the menu bar.") }
    }
    private func prune() {
        lastPrune = Date()
        if retention > 0 { do { try store.prune(before: Date().addingTimeInterval(-Double(retention) * 86400)) } catch { NSLog("History retention cleanup failed: %@",error.localizedDescription) } }
    }
    private func tick() {
        if Date().timeIntervalSince(lastPrune) > 60 { prune(); if picker?.isVisible == true && !editing { reload() } }
        let change = pasteboard.changeCount
        guard change != lastChange else { return }
        lastChange = change
        guard !paused else { return }
        // Honor common clipboard-manager privacy markers and ignore file/image copies.
        let types = pasteboard.types ?? []
        let excluded = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword", "com.apple.is-remote-clipboard"]
        guard !types.contains(where: { type in excluded.contains(where: { type.rawValue.lowercased().hasPrefix($0.lowercased()) }) }), !types.contains(.fileURL) else { return }
        let source = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let privateApps = ["com.1password", "com.agilebits", "com.bitwarden", "com.apple.keychainaccess", "com.apple.Passwords", "com.keepassxc"]
        guard !privateApps.contains(where: { source.lowercased().hasPrefix($0.lowercased()) }), let data = pasteboard.data(forType: .string), data.count <= maxBytes, let text = pasteboard.string(forType: .string), !text.isEmpty, text.utf8.count <= maxBytes else { return }
        guard change == pasteboard.changeCount else { return }
        do { try store.add(text); if picker?.isVisible == true && !editing { reload() } }
        catch { NSLog("Could not record clipboard: %@", error.localizedDescription) }
    }
    private func buildPicker() {
        picker = PickerPanel(contentRect: NSRect(x:0,y:0,width:580,height:480), styleMask:[.titled,.closable,.fullSizeContentView], backing:.buffered, defer:false)
        picker.title = appName; picker.titlebarAppearsTransparent = true; picker.isReleasedWhenClosed = false
        picker.level = .floating; picker.collectionBehavior = [.moveToActiveSpace,.fullScreenAuxiliary]; picker.hidesOnDeactivate = true; picker.isMovableByWindowBackground = true
        picker.delegate = self
        let heading = label("Clipboard history", size:22); heading.font = .systemFont(ofSize:22, weight:.semibold)
        let gear = button("",target:self,action:#selector(openSettings)); gear.image = symbol("gearshape", "Settings"); gear.toolTip = "Settings"
        let header = stack([heading,flexible(),gear]); search.placeholderString = "Search copied text…"; search.delegate = self
        let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("clip")); column.width = 530; table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 58; table.intercellSpacing = NSSize(width:0,height:3); table.delegate = self; table.dataSource = self
        table.target = self; table.action = #selector(tableClick); table.onReturn = { [weak self] in guard let self = self else { return }; self.pasteRow(self.table.selectedRow) }; table.allowsMultipleSelection = false; table.selectionHighlightStyle = .regular
        table.style = .inset; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        prev = button("‹ Previous",target:self,action:#selector(previousPage)); next = button("Next ›",target:self,action:#selector(nextPage))
        let bottom = stack([footer,flexible(),prev,next])
        let help = label("Click to paste  •  Pencil to edit  •  Esc to close",size:11,secondary:true)
        let root = stack([header,search,scroll,bottom,help],vertical:true,spacing:12); root.translatesAutoresizingMaskIntoConstraints = false
        guard let view = picker.contentView else { return }; view.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:18),root.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-18),root.topAnchor.constraint(equalTo:view.topAnchor,constant:36),root.bottomAnchor.constraint(equalTo:view.bottomAnchor,constant:-16),header.widthAnchor.constraint(equalTo:root.widthAnchor),search.widthAnchor.constraint(equalTo:root.widthAnchor),scroll.widthAnchor.constraint(equalTo:root.widthAnchor),bottom.widthAnchor.constraint(equalTo:root.widthAnchor)])
        scroll.setContentHuggingPriority(.defaultLow, for:.vertical); scroll.setContentCompressionResistancePriority(.defaultLow, for:.vertical)
    }
    @objc func openPicker() {
        guard !editing, !pasting else { return }
        if picker.isVisible && picker.isKeyWindow { picker.orderOut(nil); return }
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier != ProcessInfo.processInfo.processIdentifier ? front : nil
        tick(); page = 0; search.stringValue = ""; reload()
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
            let f = screen.visibleFrame; picker.setFrameOrigin(NSPoint(x:f.midX-picker.frame.width/2,y:f.midY-picker.frame.height/2))
        }
        activateSelf(); picker.makeKeyAndOrderFront(nil); picker.makeFirstResponder(search)
    }
    func controlTextDidChange(_ obj: Notification) {
        searchWork?.cancel(); let work = DispatchWorkItem { [weak self] in self?.page = 0; self?.reload() }; searchWork = work; DispatchQueue.main.asyncAfter(deadline:.now()+0.18,execute:work)
    }
    private func reload() {
        guard store != nil, picker != nil else { return }
        do {
            let query = search.stringValue; let count = try store.count(search:query)
            let pages = max(1,(count+pageSize-1)/pageSize); page = min(page,pages-1)
            clips = try store.page(search:query,limit:pageSize,offset:page*pageSize); table.reloadData()
            footer.stringValue = "\(count) clips · Page \(page+1) of \(pages)" + (paused ? " · Paused" : "")
            prev.isEnabled = page > 0; next.isEnabled = page+1 < pages
        } catch { footer.stringValue = "History unavailable"; NSLog("History query failed: %@",error.localizedDescription) }
    }
    @objc private func previousPage() { page = max(0,page-1); reload(); if !clips.isEmpty { table.scrollRowToVisible(0) } }
    @objc private func nextPage() { page += 1; reload(); if !clips.isEmpty { table.scrollRowToVisible(0) } }
    func numberOfRows(in tableView: NSTableView) -> Int { clips.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let clip = clips[row]; let cell = NSView()
        let preview = label(clip.text.replacingOccurrences(of:"\n",with:" ↵ ").replacingOccurrences(of:"\r",with:" "),size:13); preview.lineBreakMode = .byTruncatingTail; preview.maximumNumberOfLines = 1
        let date = label(dates.string(from:clip.copied),size:11,secondary:true)
        let details = stack([preview,date],vertical:true,spacing:4); details.setContentCompressionResistancePriority(.defaultLow,for:.horizontal); preview.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        let edit = ClipButton(title:"",target:self,action:#selector(editClip(_:))); edit.clipID = clip.id; edit.image = symbol("pencil", "Edit before pasting"); edit.toolTip = "Edit before pasting"; edit.bezelStyle = .texturedRounded
        let remove = ClipButton(title:"",target:self,action:#selector(deleteClip(_:))); remove.clipID = clip.id; remove.image = symbol("trash", "Delete from history"); remove.toolTip = "Delete from history"; remove.bezelStyle = .texturedRounded
        let line = stack([details,flexible(),edit,remove]); line.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(line)
        NSLayoutConstraint.activate([line.leadingAnchor.constraint(equalTo:cell.leadingAnchor,constant:8),line.trailingAnchor.constraint(equalTo:cell.trailingAnchor,constant:-6),line.centerYAnchor.constraint(equalTo:cell.centerYAnchor),preview.widthAnchor.constraint(lessThanOrEqualTo:details.widthAnchor),edit.widthAnchor.constraint(equalToConstant:34),remove.widthAnchor.constraint(equalToConstant:34)])
        return cell
    }
    @objc private func tableClick() { pasteRow(table.clickedRow) }
    private func pasteRow(_ row: Int) {
        guard clips.indices.contains(row), !editing, !pasting else { return }
        do { if let clip = try store.get(clips[row].id) { paste(clip.text) } } catch { report(error) }
    }
    @objc private func deleteClip(_ sender: ClipButton) { do { try store.remove(sender.clipID); reload() } catch { report(error) } }
    @objc private func editClip(_ sender: ClipButton) {
        do {
            guard let clip = try store.get(sender.clipID) else { return }; editing = true
            let a = NSAlert(); a.messageText = "Edit before pasting"; a.informativeText = "Choose whether the edited text replaces the original history entry or is pasted only this time."
            let scroll = NSScrollView(frame:NSRect(x:0,y:0,width:460,height:210)); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
            let text = NSTextView(frame:scroll.bounds); text.isRichText = false; text.isVerticallyResizable = true; text.isHorizontallyResizable = false; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true; text.font = .monospacedSystemFont(ofSize:13,weight:.regular); text.string = clip.text; scroll.documentView = text
            a.accessoryView = scroll; a.addButton(withTitle:"Paste & Keep Original"); a.addButton(withTitle:"Update History & Paste"); a.addButton(withTitle:"Cancel")
            a.window.initialFirstResponder = text
            a.beginSheetModal(for:picker) { [weak self] response in
                guard let self = self else { return }; self.editing = false
                guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else { return }
                let edited = text.string
                guard edited.utf8.count <= maxBytes else { self.alert("Text is too large", "The maximum size per text entry is 1 MiB."); return }
                do { if response == .alertSecondButtonReturn { try self.store.replace(clip,with:edited) }; self.paste(edited) } catch { self.report(error) }
            }
        } catch { editing = false; report(error) }
    }
    private func paste(_ text: String) {
        guard !pasting else { return }; pasting = true
        pasteboard.clearContents(); let ok = pasteboard.setString(text,forType:.string); lastChange = pasteboard.changeCount
        picker.orderOut(nil)
        guard ok else { pasting = false; alert("Could not write to clipboard"); return }
        guard let target = previousApp, !target.isTerminated else { pasting = false; alert("Copied to clipboard", "Press ⌘V in your destination app."); return }
        let trusted = AXIsProcessTrusted()
        if #available(macOS 14.0, *) { target.activate(options: []) }
        else { target.activate(options:[.activateIgnoringOtherApps]) }
        guard trusted else { pasting = false; return }
        waitForTarget(target, remaining: 15, expectedChange: lastChange)
    }
    private func waitForTarget(_ target: NSRunningApplication, remaining: Int, expectedChange: Int) {
        DispatchQueue.main.asyncAfter(deadline:.now()+0.08) { [weak self] in
            guard let self = self else { return }
            guard pasteboard.changeCount == expectedChange else { self.pasting = false; return }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
                let source = CGEventSource(stateID:.combinedSessionState)
                let down = CGEvent(keyboardEventSource:source,virtualKey:CGKeyCode(kVK_ANSI_V),keyDown:true)
                let up = CGEvent(keyboardEventSource:source,virtualKey:CGKeyCode(kVK_ANSI_V),keyDown:false)
                down?.flags = .maskCommand; up?.flags = .maskCommand; down?.post(tap:.cghidEventTap); up?.post(tap:.cghidEventTap); self.pasting = false
            } else if remaining > 0 && !target.isTerminated { self.waitForTarget(target,remaining:remaining-1,expectedChange:expectedChange) }
            else { self.pasting = false }
        }
    }
    @objc private func openSettings() {
        if let w = settingsWindow { picker.orderOut(nil); activateSelf(); w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect:NSRect(x:0,y:0,width:480,height:450),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        w.title = "Brightery Clipboard Settings"; w.isReleasedWhenClosed = false; w.center()
        let title = label("Preferences",size:23); title.font = .systemFont(ofSize:23,weight:.semibold)
        let reset = NSPopUpButton(frame:.zero,pullsDown:false)
        for (name,value) in [("Never reset",0),("After 24 hours",1),("After 7 days",7),("After 30 days",30),("After 90 days",90),("When I quit the app",-1)] {
            reset.addItem(withTitle:name); reset.lastItem?.tag = value
        }
        reset.selectItem(withTag:retention); reset.target = self; reset.action = #selector(changeRetention(_:))
        let sizes = NSPopUpButton(frame:.zero,pullsDown:false)
        for n in [10,20,50,100] { sizes.addItem(withTitle:"\(n) items"); sizes.lastItem?.tag = n }
        sizes.selectItem(withTag:pageSize); sizes.target = self; sizes.action = #selector(changePageSize(_:))
        let login = NSButton(checkboxWithTitle:"Open automatically at login",target:self,action:#selector(changeLogin(_:)))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let resetRow = stack([label("History retention"),flexible(),reset]); let sizeRow = stack([label("Items per page"),flexible(),sizes])
        let permission = button("Accessibility permission…",target:self,action:#selector(requestPermission)); let clear = button("Clear history…",target:self,action:#selector(clearHistory))
        let privacy = NSTextField(wrappingLabelWithString:"Text is stored locally. Images and files are not recorded. Protected clipboard markers and common password managers are skipped, but sensitive text copied elsewhere can still be saved. Pause recording whenever needed.")
        privacy.font = .systemFont(ofSize:12); privacy.textColor = .secondaryLabelColor
        let shortcut = label("Global shortcut:  ⌘ Shift V",size:13,secondary:true)
        let divider1 = NSBox.clipSeparator(); let divider2 = NSBox.clipSeparator()
        let root = stack([title,shortcut,divider1,resetRow,sizeRow,login,divider2,privacy,permission,clear],vertical:true,spacing:12)
        root.translatesAutoresizingMaskIntoConstraints = false; w.contentView?.addSubview(root)
        if let view = w.contentView { NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:22),root.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-22),root.topAnchor.constraint(equalTo:view.topAnchor,constant:20),resetRow.widthAnchor.constraint(equalTo:root.widthAnchor),sizeRow.widthAnchor.constraint(equalTo:root.widthAnchor),privacy.widthAnchor.constraint(equalTo:root.widthAnchor),divider1.widthAnchor.constraint(equalTo:root.widthAnchor),divider2.widthAnchor.constraint(equalTo:root.widthAnchor)]) }
        settingsWindow = w; picker.orderOut(nil); activateSelf(); w.makeKeyAndOrderFront(nil)
    }
    @objc private func changeRetention(_ sender: NSPopUpButton) {
        let value = sender.selectedTag()
        if value != 0 && value != retention {
            let a = NSAlert(); a.messageText = "Change history retention?"; a.informativeText = value == -1 ? "All history will be deleted when you quit normally." : "Entries older than the selected duration will be permanently deleted now and automatically while the app runs."; a.addButton(withTitle:"Apply"); a.addButton(withTitle:"Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { sender.selectItem(withTag:retention); return }
        }
        defaults.set(value,forKey:"retention"); prune(); reload()
    }
    @objc private func changePageSize(_ sender: NSPopUpButton) { defaults.set(sender.selectedTag(),forKey:"pageSize"); page = 0; reload() }
    @objc private func changeLogin(_ sender: NSButton) {
        do { if sender.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { report(error) }
        sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
        if SMAppService.mainApp.status == .requiresApproval { alert("Approve login item", "Open System Settings → General → Login Items to enable Brightery Clipboard.") }
    }
    @objc private func clearHistory() {
        let a = NSAlert(); a.alertStyle = .warning; a.messageText = "Clear all clipboard history?"; a.informativeText = "This permanently deletes saved entries, but does not change the current system clipboard."; a.addButton(withTitle:"Clear History"); a.addButton(withTitle:"Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        do { try store.clear(); page = 0; reload() } catch { report(error) }
    }
}
extension NSBox {
    static func clipSeparator() -> NSBox { let b = NSBox(); b.boxType = .separator; return b }
}
let application = NSApplication.shared
let delegate = App()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
