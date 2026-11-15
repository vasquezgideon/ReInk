import Foundation

/// Wraps a value so it can cross into and out of a detached task. Used for
/// CoreGraphics images and render results, which are immutable once made.
struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
}

enum Background {
    /// Runs CPU-heavy work (decoding, rendering, dithering) off the main actor.
    static func run<T>(_ work: @escaping @Sendable () -> T) async -> T {
        let box = await Task.detached(priority: .userInitiated) {
            UncheckedBox(value: work())
        }.value
        return box.value
    }
}
