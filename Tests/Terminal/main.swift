// Checks for terminal panes, run by scripts/test-terminal.sh: compiled with the whole app module (all of
// Sources/Satellite except main.swift) and run as a background accessory process, against your real login shell.
// It runs only echo, command -v, cat and exit there, pastes nothing onto the real clipboard, and leaves no files.
import AppKit
import SwiftTerm

let app = SatelliteApplication.shared
app.setActivationPolicy(.accessory)
var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "PASS: \(what)" : "FAIL: \(what)"); if !ok { failures += 1 } }
func pump(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

MainActor.assumeIsolated {
    // --- Config: terminal entries need no url, old entries are unchanged.
    let decoded = try! JSONDecoder().decode([WebApp].self, from: Data(#"[{"id":"t","name":"T","symbol":"terminal","terminal":{}},{"id":"c","name":"C","symbol":"x","url":"https://claude.ai/"}]"#.utf8))
    check(decoded[0].isTerminal && decoded[0].url.absoluteString == "satellite://terminal/t" && !decoded[1].isTerminal, "config: a terminal needs no url; a web entry is unchanged")
    let written = String(decoding: try! JSONEncoder().encode(decoded[0]), as: UTF8.self)
    check(!written.contains("url") && written.contains("terminal"), "config: written back without a url \u{2014} \(written)")
    check(AppConfig.defaults.assistants.contains { $0.id == "terminal" && $0.terminal == TerminalConfig() }, "defaults include a login-shell Terminal")

    // --- Launch plans.
    let plain = TerminalPane.launch(for: TerminalConfig(), shell: "/bin/zsh", home: "/Users/x", environment: ["PATH": "/usr/bin:/bin"])
    check(plain.args.isEmpty && plain.execName == "-zsh" && plain.directory == "/Users/x", "no command: an interactive login shell (argv[0] \u{201C}-zsh\u{201D}) in home")
    check(plain.environment.contains("TERM=xterm-256color") && plain.environment.contains("COLORTERM=truecolor") && plain.environment.contains("TERM_PROGRAM=Satellite"), "terminal environment set")
    let cmd = TerminalPane.launch(for: TerminalConfig(command: "claude", directory: "~"), shell: "/bin/zsh", home: NSHomeDirectory())
    check(cmd.args == ["-l", "-i", "-c", "claude; exec '/bin/zsh' -l"] && cmd.directory == NSHomeDirectory(), "a command runs in the login shell, then the shell stays: \(cmd.args)")
    check(TerminalPane.directory("~/definitely-missing-folder", home: "/Users/x") == "/Users/x", "a folder that doesn't exist falls back to home")

    // --- A real session, hosted like the panel does.
    let window = NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: 720, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
    let terminal = TerminalPane(id: "terminal", name: "Terminal", config: TerminalConfig())
    window.contentView = terminal.view
    window.orderFrontRegardless()
    terminal.startIfNeeded()
    func screen() -> String { String(decoding: terminal.view.getBufferAsData(), as: UTF8.self) }
    func waitFor(_ text: String, _ seconds: Double = 15) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if screen().contains(text) { return true }; pump(0.2) }
        return false
    }
    func type(_ text: String) { terminal.view.send(source: terminal.view, data: ArraySlice(Array(text.utf8))) }

    pump(3)   // let the profile load and the prompt appear
    type("echo SAT_MARK_$((40+2)); command -v claude || echo NO_CLAUDE\r")
    check(waitFor("SAT_MARK_42"), "the login shell runs commands")
    if FileManager.default.isExecutableFile(atPath: NSHomeDirectory() + "/.local/bin/claude") {
        check(waitFor("/.local/bin/claude"), "PATH from your profile applies: claude resolves")
    } else {
        print("SKIP: claude isn\u{2019}t installed in ~/.local/bin, so PATH from the profile isn\u{2019}t checked through it")
    }

    // Bracketed paste at the zsh prompt: the text waits there, its lines don't run.
    let marker = NSTemporaryDirectory() + "satellite-paste-\(UUID().uuidString)"
    check(terminal.paste("touch \(marker)\necho SHOULD_NOT_RUN") == .pasted, "zsh at its prompt accepts a safe (bracketed) paste")
    pump(1.5)
    check(!FileManager.default.fileExists(atPath: marker), "the pasted lines did not run (no file created)")
    let flat = screen().replacingOccurrences(of: "\n", with: "")
    check(flat.contains("touch \(marker)") && flat.contains("echo SHOULD_NOT_RUN") && !screen().contains("\nSHOULD_NOT_RUN"), "the pasted text sits at the prompt, waiting for Return (both lines, neither run)")
    type("\u{03}")   // Ctrl+C: drop the pasted line
    pump(0.8)

    // A program without bracketed paste: refused, so lines can't run as commands.
    type("cat\r")
    pump(1)
    check(terminal.paste("line one\nline two") == .unsafe, "while cat runs (no bracketed paste) a paste is refused")
    type("\u{03}")
    pump(0.8)

    // Exit, then Return starts a new session.
    type("exit\r")
    let end = Date().addingTimeInterval(8); while terminal.isRunning && Date() < end { pump(0.2) }
    check(!terminal.isRunning && waitFor("Session ended", 3), "exiting shows that the session ended")
    check(terminal.paste("x") == .notRunning, "nothing is pasted into an ended session")
    type("\r")
    check(terminal.isRunning, "Return starts a new session")
    type("echo SAT_AGAIN_$((1+1))\r")
    check(waitFor("SAT_AGAIN_2"), "the new session works")

    // --- Themes (Gogh), read back from the terminal engine itself: the shell asks it for color 1 (OSC 4) and the
    // background (OSC 11), and prints what it answers.
    check(TerminalTheme.all.count == GoghThemes.count && GoghThemes.count == 1251, "all \(GoghThemes.count) bundled Gogh themes load (\(TerminalTheme.all.count))")
    check(Set(TerminalTheme.all.map(\.name)).count == TerminalTheme.all.count && TerminalTheme.all.allSatisfy { $0.ansi.count == 16 }, "every theme has a unique name and 16 ANSI colors")
    let index = { (name: String) in TerminalTheme.all.firstIndex { $0.name == name } ?? -1 }
    check(index("Dracula") < index("Dracula Lost") && index("Dracula Lost") < index("DraculaPlus"), "themes are listed by name (Dracula, Dracula Lost, DraculaPlus)")
    let dracula = TerminalTheme.named("Dracula")!, nord = TerminalTheme.named("Nord")!
    check(dracula.isDark && dracula.background == TerminalTheme.RGB(hex: "282A36") && dracula.ansi[1] == TerminalTheme.RGB(hex: "FF5555"), "Dracula has its known colors")
    let themedEntry = try! JSONDecoder().decode(WebApp.self, from: Data(#"{"id":"t","name":"T","symbol":"terminal","terminal":{"theme":"Dracula"}}"#.utf8))
    check(themedEntry.terminal?.theme == "Dracula" && String(decoding: try! JSONEncoder().encode(themedEntry), as: UTF8.self).contains(#""theme":"Dracula""#), "a theme is kept in config.json")

    var queries = 0
    func ask(_ code: String) -> String {
        queries += 1
        let tag = "Q\(queries)"
        type(#"printf '\e]"# + code + #";?\e\\'; read -rs -t 2 -d '\' r; print -r -- ""# + tag + #"[${${r#*rgb:}%$'\e'}]""# + "\r")
        let end = Date().addingTimeInterval(6)
        // The typed command also shows the tag (the shell echoes it), so only the last one, holding a real
        // rgb answer, counts.
        while Date() < end {
            let text = screen()
            if let range = text.range(of: tag + "[", options: .backwards), let close = text[range.upperBound...].firstIndex(of: "]") {
                let answer = String(text[range.upperBound..<close])
                if answer.range(of: #"^[0-9a-f]{4}/[0-9a-f]{4}/[0-9a-f]{4}$"#, options: .regularExpression) != nil { return answer }
            }
            pump(0.2)
        }
        return "(no answer)"
    }
    let systemRed = ask("4;1")
    terminal.update(name: "Terminal", config: TerminalConfig(theme: "Dracula"))
    check(ask("4;1") == "ffff/5555/5555" && ask("11") == "2828/2a2a/3636", "choosing Dracula changes the terminal\u{2019}s real palette and background, live")
    terminal.update(name: "Terminal", config: TerminalConfig(theme: "Nord"))
    check(ask("11") == "2e2e/3434/4040", "switching to Nord applies at once")
    terminal.update(name: "Terminal", config: TerminalConfig(theme: nil))
    check(ask("4;1") == systemRed, "System restores the standard palette (\(systemRed))")
    terminal.view.appearance = NSAppearance(named: .aqua)
    pump(0.5)
    let lightBackground = ask("11")
    terminal.view.appearance = NSAppearance(named: .darkAqua)
    pump(0.5)
    let darkBackground = ask("11")
    let darkRed = Int(darkBackground.prefix(4), radix: 16) ?? 0xFFFF, lightRed = Int(lightBackground.prefix(4), radix: 16) ?? 0
    check(darkRed < 0x6000 && lightRed > 0xC000, "System follows light and dark mode: the terminal\u{2019}s own background goes from \(lightBackground) to \(darkBackground)")
    terminal.update(name: "Terminal", config: TerminalConfig(theme: "Dracula"))
    terminal.view.appearance = NSAppearance(named: .aqua)
    pump(0.5)
    check(ask("11") == "2828/2a2a/3636", "a Gogh theme stays as it is when the appearance changes")
    terminal.view.appearance = nil
    terminal.update(name: "Terminal", config: TerminalConfig(theme: nil))
    terminal.update(name: "Terminal", config: TerminalConfig(theme: "No Such Theme"))
    check(ask("4;1") == systemRed, "an unknown theme name falls back to System")

    terminal.saveTheme(nord)
    let savedEntry = AppsModel.shared.config.assistants.first { $0.id == "terminal" }
    let onDisk = (try? String(contentsOf: AppPaths.config, encoding: .utf8)) ?? ""
    check(savedEntry?.terminal?.theme == "Nord" && onDisk.contains("\"theme\" : \"Nord\""), "saving a theme writes it to this terminal\u{2019}s entry in config.json")
    terminal.saveTheme(nil)
    check(AppsModel.shared.config.assistants.first { $0.id == "terminal" }?.terminal?.theme == nil, "choosing System again clears it")

    let click = NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 20, y: 20), modifierFlags: [], timestamp: 0,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    let contextMenu = terminal.view.menu(for: click)
    let themeMenu = contextMenu?.items.first { $0.title == "Theme" }?.submenu
    check(contextMenu?.items.map(\.title).filter { !$0.isEmpty } == ["Copy", "Paste", "Select All", "Theme"]
          && themeMenu?.items.first?.title == "System" && themeMenu?.items.first?.state == .on && themeMenu?.items.last?.title == "Choose Theme\u{2026}",
          "right-click menu: Copy, Paste, Select All, Theme \u{25B8} System \u{2713} \u{2026} Choose Theme\u{2026}")

    // --- Padding, in characters.
    let decodedPadding = try! JSONDecoder().decode(TerminalConfig.self, from: Data(#"{"padding":2}"#.utf8))
    check(decodedPadding.padding == 2 && TerminalConfig(padding: 50).effectivePadding == 10 && TerminalConfig(padding: -3).effectivePadding == 0 && TerminalConfig().effectivePadding == 0,
          "padding reads from config.json and stays within 0\u{2013}10 characters")
    check(AppEditor.describePadding(0) == "None" && AppEditor.describePadding(1) == "1 character" && AppEditor.describePadding(1.5) == "1.5 characters" && AppEditor.describePadding(2) == "2 characters",
          "the editor describes it in characters")

    let padded = TerminalPane(id: "padded", name: "Padded", config: TerminalConfig(theme: "Dracula", padding: 2))
    let padWindow = NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: 640, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    padWindow.contentView = padded.host
    padWindow.orderFrontRegardless()
    padded.startIfNeeded()
    pump(1.5)
    padWindow.contentView?.layoutSubtreeIfNeeded()
    let char = TerminalPane.characterWidth(padded.view.font)
    let frame = padded.view.frame, hostBounds = padded.host.bounds
    let expected = (2 * char).rounded()
    check(abs(frame.minX - expected) < 0.5 && abs(hostBounds.maxX - frame.maxX - expected) < 0.5 && abs(frame.minY - expected) < 0.5 && abs(hostBounds.maxY - frame.maxY - expected) < 0.5,
          "2 characters of padding on every side: \(expected) pt with a \(String(format: "%.2f", char)) pt character (text at x=\(frame.minX))")
    let colsPadded = padded.view.terminalDimensions.cols
    padded.update(name: "Padded", config: TerminalConfig(theme: "Dracula", padding: nil))
    padWindow.contentView?.layoutSubtreeIfNeeded()
    pump(0.6)
    let colsFlush = padded.view.terminalDimensions.cols
    check(padded.view.frame.minX == 0 && colsFlush > colsPadded, "padding changes live: none gives the terminal \(colsFlush) columns, 2 characters gave it \(colsPadded)")
    padded.update(name: "Padded", config: TerminalConfig(theme: "Dracula", padding: 2))
    let before = padded.paddingPoints
    _ = padded.zoom(.larger); _ = padded.zoom(.larger)
    padWindow.contentView?.layoutSubtreeIfNeeded()
    check(padded.paddingPoints > before && abs(padded.view.frame.minX - padded.paddingPoints.rounded()) < 0.5, "it grows with the text size (\(before.rounded()) \u{2192} \(padded.paddingPoints.rounded()) pt)")
    _ = padded.zoom(.reset)

    func fillHex(_ host: TerminalHostView) -> String {
        host.displayIfNeeded()
        guard let color = host.layer?.backgroundColor.flatMap({ NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }) else { return "none" }
        return String(format: "%02X%02X%02X", Int((color.redComponent * 255).rounded()), Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
    }
    check(fillHex(padded.host) == "282A36", "the padding is Dracula\u{2019}s background, so it looks part of the terminal (\(fillHex(padded.host)))")
    padded.update(name: "Padded", config: TerminalConfig(theme: nil, padding: 2))
    padded.host.appearance = NSAppearance(named: .darkAqua)
    pump(0.4)
    let darkFill = fillHex(padded.host)
    padded.host.appearance = NSAppearance(named: .aqua)
    pump(0.4)
    check(darkFill != fillHex(padded.host) && fillHex(padded.host) == "FFFFFF", "with System it follows light and dark (\(fillHex(padded.host)) light, \(darkFill) dark)")
    padded.host.appearance = nil

    padWindow.makeFirstResponder(nil)
    padded.host.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 3, y: 3), modifierFlags: [], timestamp: 0,
                                                    windowNumber: padWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
    check(padWindow.firstResponder === padded.view, "a click in the padding puts the focus in the terminal")
    padded.teardown()

    // --- The panel: a web assistant and a terminal side by side.
    let panel = AssistantsViewController()
    let web = WebApp(id: "web", name: "Web", url: URL(string: "about:blank")!, symbol: "globe")
    let term = WebApp.makeTerminal(id: "term", name: "Term")
    let host = NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: 500, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
    host.contentViewController = panel
    host.orderFrontRegardless()
    panel.setItems([SidebarItem(web), SidebarItem(term)])
    panel.select("term")
    check(panel.selectedTerminal != nil && panel.selectedPane == nil, "selecting the terminal: no web page is in front")
    check(panel.selectedTerminal?.host.isHidden == false && panel.selectedTerminal?.view.isDescendant(of: panel.view) == true && panel.selectedTerminal?.isRunning == true, "the terminal (with its padding) is shown and its shell started")
    let shownTerminal = panel.selectedTerminal
    panel.select("web")
    check(panel.selectedPane != nil && panel.selectedTerminal == nil && shownTerminal?.host.isHidden == true, "selecting the web assistant switches back and hides the terminal")
    panel.setItems([SidebarItem(web)])
    check(panel.selectedTerminal == nil, "removing the terminal entry removes it")

    // --- Send to Assistant into a terminal, through the real sender.
    let pageFile = URL(fileURLWithPath: NSTemporaryDirectory() + "satellite-term-\(UUID().uuidString).html")
    try! "<p id=p>Case 00123456: login fails</p>".write(to: pageFile, atomically: true, encoding: .utf8)
    let source = WebPane(name: "Page", url: pageFile)
    let srcWindow = NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    srcWindow.contentView = source.webView
    srcWindow.orderFrontRegardless()
    source.loadIfNeeded()
    pump(2)
    var selected = false
    source.webView.evaluateJavaScript("getSelection().selectAllChildren(document.getElementById('p')); 'ok'") { _, _ in selected = true }
    while !selected { pump(0.1) }
    let sender = AssistantSender()
    sender.pasteboard = NSPasteboard(name: NSPasteboard.Name("satellite-term-test-\(UUID().uuidString)"))
    sender.confirm = { _, _, _ in AssistantSender.Answer(send: true, remember: false) }
    var toasts: [String] = []
    sender.toast = { text, _, _ in toasts.append(text) }
    var outcome: AssistantSender.Outcome?
    let item = SidebarItem(WebApp.makeTerminal(id: "terminal", name: "Terminal"))
    Task { @MainActor in
        outcome = await sender.send(from: source, to: item, selectionOnly: true, window: nil) { _ in .terminal(terminal) }
    }
    let deadline = Date().addingTimeInterval(10); while outcome == nil && Date() < deadline { pump(0.2) }
    check(outcome == .inserted(.selection), "Send to Assistant pastes the selection into the terminal \u{2014} \(toasts.last ?? "")")
    check(waitFor("Case 00123456: login fails"), "the quoted selection is at the terminal prompt, not run")
    type("\u{03}")
    pump(0.5)

    terminal.teardown()
    try? FileManager.default.removeItem(at: pageFile)
}
print(failures == 0 ? "\nAll terminal checks passed." : "\n\(failures) failed.")
exit(failures == 0 ? 0 : 1)
