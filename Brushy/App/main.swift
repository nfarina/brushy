#if !UNIT_TESTS
import AppKit

// Entry point. The delegate must be retained for the app's lifetime.
private let appDelegate = AppDelegate()
NSApplication.shared.delegate = appDelegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
#endif
