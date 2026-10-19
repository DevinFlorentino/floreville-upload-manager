import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    // Fixed size and position so the demo recording is framed predictably.
    let size = NSSize(width: 1280, height: 820)
    let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let origin = NSPoint(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2)
    self.setFrame(NSRect(origin: origin, size: size), display: true)
    self.title = "Floreville Upload Manager"


    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
