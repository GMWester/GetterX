import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    // Pass command-line arguments (e.g. --background-check) to Dart main().
    let project = FlutterDartProject()
    project.dartEntrypointArguments = Array(CommandLine.arguments.dropFirst())
    let flutterViewController = FlutterViewController(project: project)
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()

    if CommandLine.arguments.contains("--background-check") {
      // Scheduled check: no window, no Dock icon.
      NSApp.setActivationPolicy(.prohibited)
      self.orderOut(nil)
    }
  }
}
