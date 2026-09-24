import Foundation

/// WndrGram diagnostics: writes to the system log (visible with
/// `idevicesyslog`), tagged so it can be filtered out of the noise.
public func wndrTrace(_ message: @autoclosure () -> String) {
    NSLog("[WNDR] %@", message())
}
