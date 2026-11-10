import AppKit

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let engineDelegate = EngineDelegate()
application.delegate = engineDelegate
application.run()
