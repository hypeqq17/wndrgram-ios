import Foundation
import os.log

private let wndrLog = OSLog(subsystem: "wndrgram", category: "trace")

/// WndrGram diagnostics: writes to the system log (visible with
/// `idevicesyslog`), marked public so iOS does not redact it as <private>.
public func wndrTrace(_ message: @autoclosure () -> String) {
    os_log("[WNDR] %{public}@", log: wndrLog, type: .default, message() as NSString)
}
