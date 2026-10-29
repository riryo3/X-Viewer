// X-Viewer — X（旧Twitter）を見るためだけの簡易ブラウザ
// 中身は WKWebView ひとつ。X の中だけをこの窓で開き、
// 外のサイトへのリンクは普段のブラウザで開く。
// ボタンは画面の縁に広く配置する: 左端=戻る / 右端=進む / 上端=ホーム / 下端=自分のプロフィール。
import Cocoa
import WebKit

let homeURL = URL(string: "https://x.com/home")!

/// 入力（プロフィール URL でも @username でも）からユーザー名を取り出す
func parseUsername(_ raw: String) -> String? {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.isEmpty { return nil }
    if let range = s.range(of: "x.com/") {
        s = String(s[range.upperBound...])
    } else if let range = s.range(of: "twitter.com/") {
        s = String(s[range.upperBound...])
    }
    s = s.trimmingCharacters(in: CharacterSet(charactersIn: "@"))
    s = s.split(separator: "/").first.map(String.init) ?? s
    s = s.split(separator: "?").first.map(String.init) ?? s
    let ok = s.range(of: "^[A-Za-z0-9_]{1,15}$", options: .regularExpression) != nil
    return ok ? s : nil
}

/// この窓の中で開いてよいホストかどうか
func isXHost(_ host: String?) -> Bool {
    guard let h = host?.lowercased() else { return true } // about: などホスト無しは許可
    if h == "x.com" || h == "twitter.com" || h == "t.co" { return true }
    return h.hasSuffix(".x.com") || h.hasSuffix(".twitter.com") || h.hasSuffix(".t.co")
}

/// 画面の縁に置く大きなクリック領域。普段はうっすら、乗せると少し濃くなる。
final class EdgeZone: NSView {
    var onClick: (() -> Void)?
    var symbol = ""
    var isEnabledZone = true { didSet { needsDisplay = true } }
    weak var scrollTarget: NSView?
    private var hovering = false { didSet { needsDisplay = true } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true // システムのライト/ダーク切り替えに追随する
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func cursorUpdate(with event: NSEvent) {
        (isEnabledZone ? NSCursor.pointingHand : NSCursor.arrow).set()
    }
    override func mouseDown(with event: NSEvent) {
        if isEnabledZone { onClick?() }
    }
    // 縁の上でもホイールでページをスクロールできるように、WebView へ回す
    override func scrollWheel(with event: NSEvent) {
        if let target = scrollTarget {
            target.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let base = NSColor.labelColor
        base.withAlphaComponent(hovering && isEnabledZone ? 0.14 : 0.05).setFill()
        bounds.fill()
        guard let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else { return }
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let sym = img.withSymbolConfiguration(config) ?? img
        let rect = NSRect(x: (bounds.width - sym.size.width) / 2,
                          y: (bounds.height - sym.size.height) / 2,
                          width: sym.size.width, height: sym.size.height)
        sym.draw(in: rect)
        base.withAlphaComponent(isEnabledZone ? (hovering ? 0.85 : 0.4) : 0.12).setFill()
        rect.fill(using: .sourceAtop)
    }
}

final class ViewController: NSViewController, WKNavigationDelegate, WKUIDelegate {
    var webView: WKWebView!
    var backZone: EdgeZone!
    var forwardZone: EdgeZone!
    var floatButton: NSButton!
    var floatOn = false
    var observations: [NSKeyValueObservation] = []

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // ログイン状態を保持する
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 860), configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsMagnification = true

        // 縁のボタン: 左端=戻る / 右端=進む / 上端・下端=ホーム
        backZone = EdgeZone()
        backZone.symbol = "chevron.left"
        backZone.toolTip = "戻る"
        backZone.onClick = { [weak self] in self?.goBack() }

        forwardZone = EdgeZone()
        forwardZone.symbol = "chevron.right"
        forwardZone.toolTip = "進む"
        forwardZone.onClick = { [weak self] in self?.goForward() }

        let topZone = EdgeZone()
        topZone.symbol = "house"
        topZone.toolTip = "ホーム"
        topZone.onClick = { [weak self] in self?.goHome() }

        let bottomZone = EdgeZone()
        bottomZone.symbol = "person.circle"
        bottomZone.toolTip = "プロフィール"
        bottomZone.onClick = { [weak self] in self?.goProfile() }

        for zone in [backZone, forwardZone, topZone, bottomZone] {
            zone?.scrollTarget = webView
            zone?.translatesAutoresizingMaskIntoConstraints = false
        }

        // ピン留めボタンは上端バーの右すみに小さく置く
        floatButton = NSButton()
        floatButton.image = NSImage(systemSymbolName: "pin", accessibilityDescription: "ピン留め")
        floatButton.toolTip = "ピン留め（最前面に固定）"
        floatButton.bezelStyle = .texturedRounded
        floatButton.target = self
        floatButton.action = #selector(toggleFloat)
        floatButton.translatesAutoresizingMaskIntoConstraints = false
        topZone.addSubview(floatButton)

        let container = NSView()
        container.addSubview(webView)
        container.addSubview(backZone)
        container.addSubview(forwardZone)
        container.addSubview(bottomZone)
        container.addSubview(topZone)
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            topZone.topAnchor.constraint(equalTo: container.topAnchor),
            topZone.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            topZone.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            topZone.heightAnchor.constraint(equalToConstant: 22),

            bottomZone.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bottomZone.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bottomZone.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bottomZone.heightAnchor.constraint(equalToConstant: 22),

            backZone.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            backZone.topAnchor.constraint(equalTo: topZone.bottomAnchor),
            backZone.bottomAnchor.constraint(equalTo: bottomZone.topAnchor),
            backZone.widthAnchor.constraint(equalToConstant: 18),

            forwardZone.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            forwardZone.topAnchor.constraint(equalTo: topZone.bottomAnchor),
            forwardZone.bottomAnchor.constraint(equalTo: bottomZone.topAnchor),
            forwardZone.widthAnchor.constraint(equalToConstant: 18),

            floatButton.trailingAnchor.constraint(equalTo: topZone.trailingAnchor, constant: -2),
            floatButton.centerYAnchor.constraint(equalTo: topZone.centerYAnchor),
            floatButton.widthAnchor.constraint(equalToConstant: 24),
        ])
        view = container

        observations.append(webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] _, _ in
            self?.updateButtons()
        })
        observations.append(webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] _, _ in
            self?.updateButtons()
        })
        observations.append(webView.observe(\.title, options: [.new]) { [weak self] _, _ in
            if let t = self?.webView.title, !t.isEmpty {
                self?.view.window?.title = t
            }
        })
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        webView.load(URLRequest(url: homeURL))
        updateButtons()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // 前回のフロート状態を復元する
        setFloat(UserDefaults.standard.bool(forKey: "floatOnTop"))
        // 初回だけ、プロフィールの設定を聞く
        if !UserDefaults.standard.bool(forKey: "profilePromptDone") {
            UserDefaults.standard.set(true, forKey: "profilePromptDone")
            if savedUsername() == nil { showProfileDialog() }
        }
    }

    /// 最前面フロートの切り替え（状態は保存される）
    func setFloat(_ on: Bool) {
        floatOn = on
        floatButton.state = on ? .on : .off
        floatButton.image = NSImage(systemSymbolName: on ? "pin.fill" : "pin",
                                    accessibilityDescription: "ピン留め")
        view.window?.level = on ? .floating : .normal
        UserDefaults.standard.set(on, forKey: "floatOnTop")
    }

    func updateButtons() {
        backZone.isEnabledZone = webView.canGoBack
        forwardZone.isEnabledZone = webView.canGoForward
    }

    @objc func goBack() { webView.goBack() }
    @objc func goForward() { webView.goForward() }
    @objc func reload() { webView.reload() }
    @objc func goHome() { webView.load(URLRequest(url: homeURL)) }
    @objc func toggleFloat() { setFloat(!floatOn) }

    @objc func goProfile() {
        if let name = savedUsername() {
            webView.load(URLRequest(url: URL(string: "https://x.com/\(name)")!))
        } else {
            showProfileDialog()
        }
    }

    @objc func editProfile() { showProfileDialog() }

    func savedUsername() -> String? {
        let s = UserDefaults.standard.string(forKey: "profileUsername")
        return (s?.isEmpty == false) ? s : nil
    }

    /// プロフィール設定ダイアログ（URL でも @username でも可）
    func showProfileDialog() {
        let alert = NSAlert()
        alert.messageText = "自分のプロフィールを設定"
        alert.informativeText = "下の縁のボタンで、自分のプロフィールへ飛べるようになります。プロフィールの URL か @ユーザー名 を入れてください。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "例: https://x.com/username または @username"
        if let name = savedUsername() { field.stringValue = "@" + name }
        alert.accessoryView = field
        alert.addButton(withTitle: "設定する")
        alert.addButton(withTitle: "あとで")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            if let name = parseUsername(field.stringValue) {
                UserDefaults.standard.set(name, forKey: "profileUsername")
            } else {
                let err = NSAlert()
                err.messageText = "ユーザー名として読み取れませんでした"
                err.informativeText = "入力は「https://x.com/ユーザー名」か「@ユーザー名」の形でお願いします。"
                err.runModal()
                showProfileDialog()
            }
        }
    }

    // MARK: - 移動の振り分け

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow); return
        }
        // X 以外の http(s) リンクは普段のブラウザで開く
        if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
           !isXHost(url.host) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        // mailto: など Web 以外のリンクも外で開く
        if let scheme = url.scheme?.lowercased(), scheme != "http" && scheme != "https",
           scheme != "about", scheme != "data", scheme != "blob" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    // target=_blank（新しい窓で開くリンク）の扱い
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if isXHost(url.host) {
                webView.load(URLRequest(url: url))
            } else {
                NSWorkspace.shared.open(url)
            }
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { updateButtons() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { updateButtons() }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        let vc = ViewController()
        window = NSWindow(contentViewController: vc)
        window.title = "X-Viewer"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.minSize = NSSize(width: 360, height: 480)
        window.setContentSize(NSSize(width: 520, height: 860))
        window.setFrameAutosaveName("XOnlyMainWindow") // 大きさと位置を覚える
        window.backgroundColor = .windowBackgroundColor // システムの外観に倣う色
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - ウインドウスナップ（画面の隅・他のウインドウの縁に吸着）

    private var snapping = false
    private let snapThreshold: CGFloat = 14

    func windowDidMove(_ notification: Notification) {
        guard !snapping, let window = window else { return }
        let frame = window.frame
        var xs: [CGFloat] = []
        var ys: [CGFloat] = []
        for screen in NSScreen.screens {
            let vf = screen.visibleFrame
            xs += [vf.minX, vf.maxX - frame.width]
            ys += [vf.minY, vf.maxY - frame.height]
        }
        // 他のアプリのウインドウの縁もスナップ先にする
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        if let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                   kCGNullWindowID) as? [[String: Any]] {
            for info in infos {
                guard let num = info[kCGWindowNumber as String] as? Int, num != window.windowNumber,
                      let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                      let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                      let rect = CGRect(dictionaryRepresentation: boundsDict)
                else { continue }
                let other = NSRect(x: rect.minX, y: primaryHeight - rect.maxY,
                                   width: rect.width, height: rect.height)
                xs += [other.minX - frame.width, other.maxX, other.minX, other.maxX - frame.width]
                ys += [other.minY - frame.height, other.maxY, other.minY, other.maxY - frame.height]
            }
        }
        let nx = snapValue(frame.origin.x, candidates: xs)
        let ny = snapValue(frame.origin.y, candidates: ys)
        if nx != frame.origin.x || ny != frame.origin.y {
            snapping = true
            window.setFrameOrigin(NSPoint(x: nx, y: ny))
            snapping = false
        }
    }

    private func snapValue(_ value: CGFloat, candidates: [CGFloat]) -> CGFloat {
        var best = value
        var bestDist = snapThreshold
        for c in candidates {
            let d = abs(c - value)
            if d <= bestDist { bestDist = d; best = c }
        }
        return best
    }

    func buildMenu() {
        let mainMenu = NSMenu()

        // アプリメニュー
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "X-Viewer について", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "X-Viewer を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // 表示メニュー（ショートカット用）
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "表示")
        viewMenu.addItem(NSMenuItem(title: "再読み込み", action: #selector(ViewController.reload), keyEquivalent: "r"))
        viewMenu.addItem(NSMenuItem(title: "戻る", action: #selector(ViewController.goBack), keyEquivalent: "["))
        viewMenu.addItem(NSMenuItem(title: "進む", action: #selector(ViewController.goForward), keyEquivalent: "]"))
        viewMenu.addItem(NSMenuItem(title: "ホームへ", action: #selector(ViewController.goHome), keyEquivalent: "H"))
        viewMenu.addItem(NSMenuItem(title: "最前面に固定（フロート）", action: #selector(ViewController.toggleFloat), keyEquivalent: "t"))
        viewMenu.addItem(NSMenuItem(title: "プロフィールを設定…", action: #selector(ViewController.editProfile), keyEquivalent: ""))
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        NSApp.mainMenu = mainMenu
    }
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
