import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// Tells the app what was chosen in the menu bar.
  private var menuChannel: FlutterMethodChannel?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    if let controller = mainFlutterWindow?.contentViewController as? FlutterViewController {
      menuChannel = FlutterMethodChannel(
        name: "reqorb/menu", binaryMessenger: controller.engine.binaryMessenger)
    }
    addMenus()
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  /// A menu item that asks the app for `command`. A key given here is shown
  /// beside the item; the app itself answers the key first wherever its
  /// main page has the keyboard.
  private func item(
    _ title: String, _ command: String, _ key: String = "",
    _ modifiers: NSEvent.ModifierFlags = [.command]
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: key)
    item.keyEquivalentModifierMask = modifiers
    item.target = self
    item.representedObject = command
    return item
  }

  @objc private func run(_ sender: NSMenuItem) {
    if let command = sender.representedObject as? String {
      menuChannel?.invokeMethod("run", arguments: command)
    }
  }

  private func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
    let menu = NSMenu(title: title)
    items.forEach(menu.addItem)
    let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    holder.submenu = menu
    return holder
  }

  /// Adds the app's own menus to those every Mac app starts with.
  private func addMenus() {
    guard let bar = NSApp.mainMenu else { return }
    let separator = NSMenuItem.separator

    // Settings…, which the app menu has but does nothing with.
    if let settings = bar.items.first?.submenu?.items.first(where: { $0.keyEquivalent == "," }) {
      settings.title = "Settings…"
      settings.target = self
      settings.action = #selector(run(_:))
      settings.representedObject = "settings"
    }

    let file = menu(
      "File",
      [
        item("New Request", "newRequest", "n"),
        item("New Collection…", "newCollection"),
        separator(),
        item("Open File…", "openFile", "o"),
        item("Open Collection Folder…", "openFolder"),
        menu(
          "Import",
          [
            item("File…", "importFile"),
            item("From a URL…", "importUrl"),
            item("Paste curl or JSON…", "importPaste"),
          ]),
        separator(),
        item("Save Request", "save", "s"),
        separator(),
        item("Duplicate Tab", "duplicateTab"),
        item("Close Tab", "closeTab", "w"),
        item("Reopen Closed Tab", "reopenTab", "t", [.command, .shift]),
      ])
    bar.insertItem(file, at: min(1, bar.items.count))

    let request = menu(
      "Request",
      [
        item("Send", "send", "\r"),
        item("Stop", "stop", "."),
        separator(),
        item("Go to Address", "focusUrl", "l"),
        item("Show as Code…", "code"),
        separator(),
        item("Environments…", "environments"),
      ])
    let tools = menu(
      "Tools",
      [
        item("History", "history"),
        item("API Specs", "specs"),
        item("HAR Analyser…", "har"),
      ])
    let window = bar.items.firstIndex { $0.submenu?.title == "Window" } ?? bar.items.count
    bar.insertItem(tools, at: window)
    bar.insertItem(request, at: window)

    if let view = bar.items.first(where: { $0.submenu?.title == "View" })?.submenu {
      let added = [
        item("Show or Hide Sidebar", "sidebar", "b"),
        item("Find Anything…", "palette", "k"),
        separator(),
        item("Larger Code", "zoomIn", "="),
        item("Smaller Code", "zoomOut", "-"),
        item("Usual Size", "zoomReset", "0"),
        separator(),
        item("Next Tab", "nextTab", "]", [.command, .shift]),
        item("Previous Tab", "previousTab", "[", [.command, .shift]),
        separator(),
      ]
      for (index, entry) in added.enumerated() {
        view.insertItem(entry, at: index)
      }
    }

    if let help = bar.items.first(where: { $0.submenu?.title == "Help" })?.submenu {
      help.insertItem(item("Keyboard Shortcuts", "shortcuts", "/"), at: 0)
    }
  }
}
