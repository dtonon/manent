import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    self.backgroundColor = .white
    showSplash()

    super.awakeFromNib()
  }

  private func showSplash() {
    guard let contentView = self.contentView else { return }

    let splash = NSView(frame: contentView.bounds)
    splash.wantsLayer = true
    splash.layer?.backgroundColor = NSColor.white.cgColor
    splash.autoresizingMask = [.width, .height]

    // Load splash.png from Flutter's bundled assets via App.framework bundle
    let frameworkPath = Bundle.main.bundlePath + "/Contents/Frameworks/App.framework"
    let frameworkBundle = Bundle(path: frameworkPath)
    let imageURL = frameworkBundle?.url(forResource: "assets/splash", withExtension: "png", subdirectory: "flutter_assets")
    if let url = imageURL, let image = NSImage(contentsOf: url) {
      let size = contentView.bounds.size
      let side = size.width * 0.4
      let imageFrame = NSRect(
        x: (size.width - side) / 2,
        y: (size.height - side) / 2,
        width: side,
        height: side
      )
      let imageView = NSImageView(frame: imageFrame)
      imageView.image = image
      imageView.imageScaling = .scaleProportionallyUpOrDown
      imageView.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
      splash.addSubview(imageView)
    }

    contentView.addSubview(splash)

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
      NSAnimationContext.runAnimationGroup({ ctx in
        ctx.duration = 0.2
        splash.animator().alphaValue = 0
      }, completionHandler: {
        splash.removeFromSuperview()
      })
    }
  }
}
