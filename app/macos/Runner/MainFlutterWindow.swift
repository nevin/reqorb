import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // Room for the sidebar, a request and its response side by side the
    // first time; after that, wherever the window was left.
    self.minSize = NSSize(width: 720, height: 520)
    let saved = "reqorb.main"
    if !self.setFrameUsingName(saved) {
      self.setContentSize(NSSize(width: 1280, height: 820))
      self.center()
    }
    self.setFrameAutosaveName(saved)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
