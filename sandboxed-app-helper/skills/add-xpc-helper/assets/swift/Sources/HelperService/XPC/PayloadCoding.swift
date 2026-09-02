import Foundation
import XPC

/// The XPC dictionary key under which the JSON-encoded ``ServiceRequest`` / ``ServiceResponse``
/// payload travels.
///
/// One key holding JSON, rather than a dictionary of typed XPC values, keeps the wire format
/// described entirely by the two `Codable` enums — there is no second, hand-rolled encoding to keep
/// in step with them.
private let payloadKey = "payload"

/// Stores `value`, JSON-encoded, as the payload of `message`.
func setPayload(_ value: some Encodable, on message: xpc_object_t) throws {
  let data = try JSONEncoder().encode(value)
  data.withUnsafeBytes { buffer in
    xpc_dictionary_set_data(message, payloadKey, buffer.baseAddress, buffer.count)
  }
}

/// Creates a fresh XPC dictionary message carrying `value` as its payload.
func makeMessage(_ value: some Encodable) throws -> xpc_object_t {
  let message = xpc_dictionary_create_empty()
  try setPayload(value, on: message)
  return message
}

/// Decodes `Value` from an XPC dictionary message's payload data.
func decodePayload<Value: Decodable>(_ type: Value.Type, from message: xpc_object_t) throws -> Value {
  var length = 0
  guard let bytes = xpc_dictionary_get_data(message, payloadKey, &length) else {
    throw ServiceRemoteError(message: "XPC message is missing its payload")
  }
  return try JSONDecoder().decode(Value.self, from: Data(bytes: bytes, count: length))
}
