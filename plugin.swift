import Cocoa

// MARK: - Lua registry compatibility
//
// Swift cannot see Lua's function-like macros (luaL_newlib, luaL_ref's
// LUA_REGISTRYINDEX, etc.), so the bridging header exposes a constant we use here.

// MARK: - Sidebar data model

struct SidebarItem {
    let title: String
    let url: URL?      // nil for section headers
    let isHeader: Bool
    let symbolName: String?

    static func header(_ title: String) -> SidebarItem {
        SidebarItem(title: title, url: nil, isHeader: true, symbolName: nil)
    }

    static func entry(_ title: String, _ url: URL, _ symbol: String) -> SidebarItem {
        SidebarItem(title: title, url: url, isHeader: false, symbolName: symbol)
    }
}

/// Builds the sidebar contents from the user's real home folders and the
/// Finder favorites (the macOS shared file list).
private func buildSidebarItems() -> [SidebarItem] {
    var items: [SidebarItem] = []

    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser

    // --- Favorites section: standard home folders that exist ---
    items.append(.header("Favorites"))

    let standard: [(String, String, String)] = [
        // (folder name relative to home, display title, SF Symbol)
        ("Desktop",   "Desktop",   "menubar.dock.rectangle"),
        ("Documents", "Documents", "doc"),
        ("Downloads", "Downloads", "arrow.down.circle"),
        ("Movies",    "Movies",    "film"),
        ("Music",     "Music",     "music.note"),
        ("Pictures",  "Pictures",  "photo"),
    ]

    // Home itself first.
    items.append(.entry(home.lastPathComponent, home, "house"))

    for (folder, title, symbol) in standard {
        let url = home.appendingPathComponent(folder, isDirectory: true)
        if fm.fileExists(atPath: url.path) {
            items.append(.entry(title, url, symbol))
        }
    }

    // --- Finder favorites (shared file list), if readable ---
    let favorites = readFinderFavorites()
    if !favorites.isEmpty {
        items.append(.header("Finder Favorites"))
        for url in favorites {
            // Skip duplicates of what we already added.
            if items.contains(where: { $0.url?.standardizedFileURL == url.standardizedFileURL }) {
                continue
            }
            items.append(.entry(url.lastPathComponent, url, "folder"))
        }
    }

    // --- Volumes ---
    if let vols = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: "/Volumes"),
                                              includingPropertiesForKeys: nil,
                                              options: [.skipsHiddenFiles]),
       !vols.isEmpty {
        items.append(.header("Locations"))
        for vol in vols {
            items.append(.entry(vol.lastPathComponent, vol, "externaldrive"))
        }
    }

    return items
}

/// Reads the Finder sidebar favorites. LSSharedFileList is deprecated but still
/// the only documented way to read the user's Finder favorites; we read it
/// defensively and just return [] if it is unavailable.
private func readFinderFavorites() -> [URL] {
    guard let list = LSSharedFileListCreate(
        nil,
        kLSSharedFileListFavoriteItems.takeUnretainedValue(),
        nil
    )?.takeRetainedValue() else {
        return []
    }

    var seed: UInt32 = 0
    guard let snapshot = LSSharedFileListCopySnapshot(list, &seed)?.takeRetainedValue()
        as? [LSSharedFileListItem] else {
        return []
    }

    var urls: [URL] = []
    for item in snapshot {
        if let cfURL = LSSharedFileListItemCopyResolvedURL(item, 0, nil)?.takeRetainedValue() {
            let url = cfURL as URL
            if url.isFileURL {
                urls.append(url)
            }
        }
    }
    return urls
}

// MARK: - Theme

/// Colors/typography mirrored from Marta's active theme so the sidebar matches
/// the main UI. Built from values parsed in init.lua and passed across the bridge.
struct Theme {
    var isDark: Bool
    var background: NSColor
    var text: NSColor
    var selection: NSColor      // files.background.current
    var selectionText: NSColor  // files.text.current
    var alternate: NSColor      // files.background.alternate
    var font: NSFont

    static let fallback = Theme(
        isDark: true,
        background: NSColor(srgbHex: "#1c2229") ?? .windowBackgroundColor,
        text: NSColor(srgbHex: "#c0c5c8") ?? .labelColor,
        selection: NSColor(srgbHex: "#1945a5") ?? .selectedContentBackgroundColor,
        selectionText: .white,
        alternate: NSColor(srgbHex: "#1a2027") ?? .windowBackgroundColor,
        font: .systemFont(ofSize: 12.5)
    )
}

extension NSColor {
    /// Parses #rgb, #rrggbb, or #aarrggbb (Marta uses an optional leading alpha).
    convenience init?(srgbHex hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard let value = UInt64(s, radix: 16) else { return nil }

        let r, g, b, a: CGFloat
        switch s.count {
        case 6:
            a = 1
            r = CGFloat((value >> 16) & 0xff) / 255
            g = CGFloat((value >> 8) & 0xff) / 255
            b = CGFloat(value & 0xff) / 255
        case 8: // AARRGGBB (Marta convention: alpha first)
            a = CGFloat((value >> 24) & 0xff) / 255
            r = CGFloat((value >> 16) & 0xff) / 255
            g = CGFloat((value >> 8) & 0xff) / 255
            b = CGFloat(value & 0xff) / 255
        default:
            return nil
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont? {
        let traits = [NSFontDescriptor.TraitKey.weight: weight]
        let descriptor = fontDescriptor.addingAttributes([.traits: traits])
        return NSFont(descriptor: descriptor, size: pointSize)
    }
}

/// Row view that draws the selection using Marta's theme selection color
/// instead of the system accent color.
final class ThemedRowView: NSTableRowView {
    var selectionColor: NSColor = .selectedContentBackgroundColor

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none, isSelected else { return }
        selectionColor.setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1),
                                xRadius: 5, yRadius: 5)
        path.fill()
    }
}

// MARK: - View controller

final class SidebarViewController: NSViewController {

    private let items: [SidebarItem]
    private let theme: Theme
    /// Called with the selected directory path. Bridged to a Lua callback.
    var onSelect: ((String) -> Void)?

    private var tableView: NSTableView!
    private var scrollView: NSScrollView!

    init(items: [SidebarItem], theme: Theme) {
        self.items = items
        self.theme = theme
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        // Solid background matching Marta's theme (no system vibrancy, so it
        // does not look lighter/translucent next to the main window).
        container.layer?.backgroundColor = theme.background.cgColor

        let table = NSTableView()
        table.style = .plain                       // plain, so we control colors
        table.headerView = nil
        table.backgroundColor = theme.background
        table.selectionHighlightStyle = .regular
        table.usesAlternatingRowBackgroundColors = false
        table.gridStyleMask = []
        table.rowSizeStyle = .custom
        table.intercellSpacing = NSSize(width: 0, height: 2)
        // Match Marta's light/dark appearance regardless of system setting.
        table.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked)
        table.action = #selector(rowClicked)
        self.tableView = table

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = theme.background
        scroll.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        self.scrollView = scroll

        container.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)

        // Navigation toolbar: Back / Forward / Up. These invoke Marta's
        // built-in actions (core.back/core.forward/core.go.up) via the same
        // callback used for folders, prefixed with "action:".
        let toolbar = makeNavigationToolbar()
        container.addSubview(toolbar)
        container.addSubview(scroll)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            toolbar.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8),
            toolbar.heightAnchor.constraint(equalToConstant: 24),

            scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        self.view = container
    }

    private func makeNavigationToolbar() -> NSView {
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY

        func button(symbol: String, fallback: String, tip: String, sel: Selector) -> NSButton {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            let b = NSButton(title: image == nil ? fallback : "", image: image ?? NSImage(),
                             target: self, action: sel)
            b.isBordered = false
            b.bezelStyle = .regularSquare
            b.imagePosition = image == nil ? .noImage : .imageOnly
            b.contentTintColor = theme.text
            b.toolTip = tip
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 26).isActive = true
            b.heightAnchor.constraint(equalToConstant: 22).isActive = true
            return b
        }

        stack.addArrangedSubview(button(symbol: "chevron.backward", fallback: "‹",
                                        tip: "Back (previously visited folder)",
                                        sel: #selector(backClicked)))
        stack.addArrangedSubview(button(symbol: "chevron.forward", fallback: "›",
                                        tip: "Forward",
                                        sel: #selector(forwardClicked)))
        stack.addArrangedSubview(button(symbol: "chevron.up", fallback: "↑",
                                        tip: "Up (parent folder)",
                                        sel: #selector(upClicked)))
        return stack
    }

    @objc private func backClicked()    { onSelect?("action:core.back") }
    @objc private func forwardClicked() { onSelect?("action:core.forward") }
    @objc private func upClicked()       { onSelect?("action:core.go.up") }

    @objc private func rowClicked() {
        emitSelection(row: tableView.clickedRow)
    }

    @objc private func rowDoubleClicked() {
        emitSelection(row: tableView.clickedRow)
    }

    private func emitSelection(row: Int) {
        guard row >= 0, row < items.count else { return }
        let item = items[row]
        guard !item.isHeader, let url = item.url else { return }
        onSelect?(url.path)
    }
}

extension SidebarViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
}

extension SidebarViewController: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        items[row].isHeader
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !items[row].isHeader
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let item = items[row]

        let headerSize = max(9, theme.font.pointSize - 1.5)

        if item.isHeader {
            let id = NSUserInterfaceItemIdentifier("header")
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView)
                ?? makeTextCell(identifier: id)
            cell.textField?.stringValue = item.title.uppercased()
            cell.textField?.font = NSFont(descriptor: theme.font.fontDescriptor, size: headerSize)?
                .withWeight(.semibold) ?? .systemFont(ofSize: headerSize, weight: .semibold)
            cell.textField?.textColor = theme.text.withAlphaComponent(0.55)
            cell.imageView?.isHidden = true
            return cell
        }

        let id = NSUserInterfaceItemIdentifier("entry")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView)
            ?? makeIconCell(identifier: id)
        cell.textField?.stringValue = item.title
        cell.textField?.font = theme.font
        cell.textField?.textColor = theme.text
        cell.imageView?.isHidden = false
        if let symbol = item.symbolName {
            cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: item.title)
        }
        cell.imageView?.contentTintColor = theme.text.withAlphaComponent(0.75)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rv = ThemedRowView()
        rv.selectionColor = theme.selection
        return rv
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let base = theme.font.pointSize
        return items[row].isHeader ? base + 13 : base + 14
    }

    // MARK: cell factories (programmatic, no XIBs)

    private func makeTextCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(tf)
        cell.textField = tf
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            tf.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -3),
        ])
        return cell
    }

    private func makeIconCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier

        let iv = NSImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.imageScaling = .scaleProportionallyDown
        cell.addSubview(iv)
        cell.imageView = iv

        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.lineBreakMode = .byTruncatingTail
        cell.addSubview(tf)
        cell.textField = tf

        NSLayoutConstraint.activate([
            iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            iv.widthAnchor.constraint(equalToConstant: 18),
            iv.heightAnchor.constraint(equalToConstant: 18),

            tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 8),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

// MARK: - Window management

private let sidebarWidth: CGFloat = 240

/// Keeps a docked sidebar glued to the left edge of its parent window, and
/// tears itself down when the parent goes away. Retained via `dockedSidebars`.
final class DockedSidebar {
    let window: NSWindow
    weak var parent: NSWindow?
    private var observers: [NSObjectProtocol] = []

    init(window: NSWindow, parent: NSWindow) {
        self.window = window
        self.parent = parent

        // Child windows automatically move with the parent and are ordered out
        // when the parent miniaturizes / closes.
        parent.addChildWindow(window, ordered: .below)
        reposition()

        let nc = NotificationCenter.default
        // Re-dock on parent move/resize so we always hug the left edge & match height.
        observers.append(nc.addObserver(forName: NSWindow.didMoveNotification,
                                        object: parent, queue: .main) { [weak self] _ in
            self?.reposition()
        })
        observers.append(nc.addObserver(forName: NSWindow.didResizeNotification,
                                        object: parent, queue: .main) { [weak self] _ in
            self?.reposition()
        })
        // Parent closed -> remove ourselves.
        observers.append(nc.addObserver(forName: NSWindow.willCloseNotification,
                                        object: parent, queue: .main) { [weak self] _ in
            self?.teardown()
        })
        // If our own window is closed by the user, also clean up.
        observers.append(nc.addObserver(forName: NSWindow.willCloseNotification,
                                        object: window, queue: .main) { [weak self] _ in
            self?.teardown()
        })
    }

    private func reposition() {
        guard let parent = parent else { return }
        let f = parent.frame
        window.setFrame(NSRect(x: f.minX - sidebarWidth, y: f.minY,
                               width: sidebarWidth, height: f.height),
                        display: true)
    }

    func teardown() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        parent?.removeChildWindow(window)
        window.orderOut(nil)
        dockedSidebars.remove(self)
    }
}

extension DockedSidebar: Hashable {
    static func == (lhs: DockedSidebar, rhs: DockedSidebar) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// Strong references so docked sidebars (and their observers) stay alive.
private var dockedSidebars: Set<DockedSidebar> = []

private func showSidebar(ownerWindow: NSWindow?,
                         theme: Theme,
                         onSelect: @escaping (String) -> Void) {
    // If this parent already has a sidebar, just bring it forward (toggle-friendly).
    if let owner = ownerWindow,
       let existing = dockedSidebars.first(where: { $0.parent === owner }) {
        existing.window.orderFront(nil)
        return
    }

    let items = buildSidebarItems()
    let vc = SidebarViewController(items: items, theme: theme)
    vc.onSelect = onSelect

    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: sidebarWidth, height: 400),
                          styleMask: [.borderless, .resizable],
                          backing: .buffered,
                          defer: false)
    window.contentViewController = vc
    window.backgroundColor = theme.background
    window.isOpaque = true
    window.hasShadow = false
    window.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
    window.collectionBehavior = [.moveToActiveSpace]

    guard let owner = ownerWindow else {
        // No parent window to dock to; show centered on the main screen as a fallback.
        if let screen = NSScreen.main {
            let v = screen.visibleFrame
            window.setFrame(NSRect(x: v.minX, y: v.minY, width: sidebarWidth, height: v.height),
                            display: true)
        }
        window.makeKeyAndOrderFront(nil)
        return
    }

    let docked = DockedSidebar(window: window, parent: owner)
    dockedSidebars.insert(docked)
    window.orderFront(nil)
}

// MARK: - Lua bridge

/// init.lua calls:
///   interop.showSidebar(nsWindow, callback,
///       appearance, bg, text, selection, selectionText, alternate,
///       fontName, fontSize)
///   arg 1: light userdata, the owner NSWindow (may be nil)
///   arg 2: a Lua function invoked with the selected path string
///   arg 3..10: theme strings/number (all optional; fall back to defaults)
private func luaStringArg(_ L: OpaquePointer, _ idx: Int32) -> String? {
    guard lua_type(L, idx) == LUA_TSTRING_COMPAT,
          let c = lua_tostring_compat(L, idx) else { return nil }
    return String(cString: c)
}

private let showSidebarFn: lua_CFunction = { state in
    guard let L = state else { return 0 }

    // Owner window (optional light userdata).
    var ownerWindow: NSWindow?
    if lua_type(L, 1) == LUA_TLIGHTUSERDATA_COMPAT, let ptr = lua_touserdata(L, 1) {
        ownerWindow = Unmanaged<NSWindow>.fromOpaque(ptr).takeUnretainedValue()
    }

    // Callback (optional function in arg 2).
    var callbackRef: Int32 = LUA_NOREF_COMPAT
    if lua_type(L, 2) == LUA_TFUNCTION_COMPAT {
        // Move the function to the top of the stack, then ref it.
        lua_pushvalue(L, 2)
        callbackRef = luaL_ref(L, LUA_REGISTRYINDEX_COMPAT)
    }

    // Theme args (all optional → fall back to Theme.fallback fields).
    var theme = Theme.fallback
    if let appearance = luaStringArg(L, 3) {
        theme.isDark = appearance.lowercased() != "light"
    }
    if let c = luaStringArg(L, 4), let color = NSColor(srgbHex: c) { theme.background = color }
    if let c = luaStringArg(L, 5), let color = NSColor(srgbHex: c) { theme.text = color }
    if let c = luaStringArg(L, 6), let color = NSColor(srgbHex: c) { theme.selection = color }
    if let c = luaStringArg(L, 7), let color = NSColor(srgbHex: c) { theme.selectionText = color }
    if let c = luaStringArg(L, 8), let color = NSColor(srgbHex: c) { theme.alternate = color }

    var fontSize: CGFloat = theme.font.pointSize
    if lua_isnumber_compat(L, 10) != 0 {
        let n = CGFloat(lua_tonumber_compat(L, 10))
        if n >= 7, n <= 40 { fontSize = n }
    }
    if let fontName = luaStringArg(L, 9), let f = NSFont(name: fontName, size: fontSize) {
        theme.font = f
    } else {
        theme.font = .systemFont(ofSize: fontSize)
    }

    showSidebar(ownerWindow: ownerWindow, theme: theme) { path in
        // Always touch the Lua state on the main thread.
        DispatchQueue.main.async {
            guard callbackRef != LUA_NOREF_COMPAT else { return }
            lua_rawgeti(L, LUA_REGISTRYINDEX_COMPAT, Int64(callbackRef))
            lua_pushstring(L, path)
            // PROTECTED call (1 arg, 0 results). Using lua_pcall — never
            // lua_call/lua_callk — so a Lua-side error becomes a return code
            // instead of a longjmp that aborts the whole Marta process.
            let status = lua_pcall_compat(L, 1, 0, 0)
            if status != LUA_OK_COMPAT {
                let msg = lua_tostring_compat(L, -1).map { String(cString: $0) } ?? "unknown error"
                NSLog("[places-sidebar] callback error: \(msg)")
                lua_pop_compat(L, 1) // pop the error message
            }
            // We keep the ref so the callback can fire on every click.
            // It is released when Lua GCs the closure / plugin reloads.
        }
    }

    return 0
}

@_cdecl("luaopen_libmartasidebar")
public func luaopen_libmartasidebar(L: OpaquePointer) -> CInt {
    let library: [(String, lua_CFunction)] = [
        ("showSidebar", showSidebarFn),
    ]

    lua_createtable(L, 0, Int32(library.count))
    for (name, function) in library {
        lua_pushcclosure(L, function, 0)
        lua_setfield(L, -2, name)
    }

    return 1
}
