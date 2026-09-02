import Foundation
import XPC

/// Vends the launchd Mach service the helper registers.
enum MachServiceListener {

  /// Creates and resumes the listener, returning a handle that keeps it alive.
  static func start(
    handler: any HelperRequestHandling,
    peerRequirement: String
  ) -> ServiceListenerHandle {
    let listener = {{SYMBOL_PREFIX}}Name.withCString { name in
      xpc_connection_create_mach_service(name, nil, UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER))
    }

    // Set before resuming: afterwards the listener is already accepting peers and the requirement
    // protects nothing. Failing loudly is right — a listener serving unverified peers is worse than
    // one that doesn't start.
    let status = peerRequirement.withCString {
      xpc_connection_set_peer_code_signing_requirement(listener, $0)
    }
    guard status == 0 else {
      fatalError("Failed to set the peer code-signing requirement (status \(status))")
    }

    let handle = ServiceListenerHandle(listener: listener)
    xpc_connection_set_event_handler(listener) { [weak handle] peer in
      guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else { return }
      accept(peer: peer, handler: handler, handle: handle)
    }
    xpc_connection_resume(listener)
    return handle
  }

  /// Wires a per-peer message handler and resumes the peer connection.
  private static func accept(
    peer: xpc_connection_t,
    handler: any HelperRequestHandling,
    handle: ServiceListenerHandle?
  ) {
    let dispatcher = RequestDispatcher(handler: handler)
    handle?.connectionOpened()
    xpc_connection_set_event_handler(peer) { [weak handle] event in
      handlePeerEvent(event, dispatcher: dispatcher, handle: handle)
    }
    xpc_connection_resume(peer)
  }

  /// Decodes one request from a peer message and replies asynchronously.
  private static func handlePeerEvent(
    _ event: xpc_object_t,
    dispatcher: RequestDispatcher,
    handle: ServiceListenerHandle?
  ) {
    if xpc_get_type(event) == XPC_TYPE_ERROR {
      guard xpc_equal(event, XPC_ERROR_CONNECTION_INVALID) else { return }
      handle?.connectionClosed()
      Task { await dispatcher.peerDisconnected() }
      return
    }
    guard xpc_get_type(event) == XPC_TYPE_DICTIONARY else { return }

    let request: ServiceRequest
    do {
      request = try decodePayload(ServiceRequest.self, from: event)
    } catch {
      // Most often an app newer than this helper sending a case it doesn't know.
      sendReply(.failure(.message("Undecodable request: \(error)")), to: event)
      return
    }
    let eventBox = UncheckedSendableBox(event)
    Task {
      sendReply(await dispatcher.response(for: request), to: eventBox.value)
    }
  }

  /// Sends `response` back to the originator of `event`, using the reply routing the message carries.
  private static func sendReply(_ response: ServiceResponse, to event: xpc_object_t) {
    guard let reply = xpc_dictionary_create_reply(event) else { return }
    do {
      try setPayload(response, on: reply)
    } catch {
      return
    }
    guard let remote = xpc_dictionary_get_remote_connection(event) else { return }
    xpc_connection_send_message(remote, reply)
  }
}
