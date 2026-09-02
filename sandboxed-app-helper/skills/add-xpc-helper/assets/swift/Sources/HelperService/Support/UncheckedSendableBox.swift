/// Wraps a non-`Sendable` value so it can cross a Swift 6 concurrency boundary.
///
/// The C XPC types are not `Sendable`, but the objects are thread-safe by contract, so boxing them is
/// sound where the surrounding code keeps the usual XPC rules.
struct UncheckedSendableBox<Wrapped>: @unchecked Sendable {
  let value: Wrapped

  init(_ value: Wrapped) {
    self.value = value
  }
}
