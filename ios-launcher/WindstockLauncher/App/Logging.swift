import Foundation

/// Swift-side front door to the shared log. The C entry point is variadic and
/// therefore not callable from Swift, so interpolate first and pass one string.
func WSLog(_ category: String, _ message: String) {
    WSLogMessage(category, message)
}
