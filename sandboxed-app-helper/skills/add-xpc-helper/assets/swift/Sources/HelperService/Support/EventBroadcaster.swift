import Foundation
import Synchronization

/// Fans events out to any number of ``AsyncStream`` subscribers.
final class EventBroadcaster<Element: Sendable>: Sendable {

  private struct Subscribers {
    var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
    var latest: Element?
  }

  private let subscribers = Mutex(Subscribers())

  /// Whether a new subscriber immediately receives the most recently broadcast element.
  private let replaysLatest: Bool

  init(replaysLatest: Bool = false) {
    self.replaysLatest = replaysLatest
  }

  /// Returns a stream of every element broadcast from now on.
  func subscribe() -> AsyncStream<Element> {
    let (stream, continuation) = AsyncStream<Element>.makeStream()
    let id = UUID()
    let replay = subscribers.withLock { subscribers -> Element? in
      subscribers.continuations[id] = continuation
      return replaysLatest ? subscribers.latest : nil
    }
    continuation.onTermination = { [weak self] _ in
      _ = self?.subscribers.withLock { $0.continuations.removeValue(forKey: id) }
    }
    if let replay { continuation.yield(replay) }
    return stream
  }

  /// Delivers `element` to every current subscriber.
  func broadcast(_ element: Element) {
    subscribers.withLock { subscribers in
      subscribers.latest = element
      for continuation in subscribers.continuations.values {
        continuation.yield(element)
      }
    }
  }
}
