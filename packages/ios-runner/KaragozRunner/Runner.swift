import CryptoKit
import Foundation
import XCTest

// The host side (packages/karagoz/src/drivers/ios/runner.ts) mirrors the port, the protocol number, the two headers and
// the text each HMAC-SHA256 covers: "karagoz-req\n<nonce>\n<METHOD> <path>\n<body>" for a request,
// "karagoz-res\n<nonce>\n<status>\n<body>" for its answer (K41, K42).
private let port: UInt16 = 27753
private let protocolVersion = 2
private let nonceHeader = "x-karagoz-nonce"
private let macHeader = "x-karagoz-mac"
// No /tree for this long ends the test, and xcodebuild exits with it: the runner stops itself, no daemon (K3).
private let idleSeconds: TimeInterval = 600
// XCTest cannot cancel a snapshot, and a blocked main thread serves nothing more, so the runner answers and exits.
private let snapshotSeconds: Double = 20
// A long text is the largest request; 1 MiB is minutes of typing.
private let maxRequestBytes = 1 << 20
// UIAccessibilityTraitHeader; the simulator's tree calls these nodes AXHeading (K34).
private let headerTrait: UInt64 = 0x10000

private struct Missing: Error {
  let name: String
}

private struct Failure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

private func selector(_ name: String) -> Selector { NSSelectorFromString(name) }

// Lowercase hex to bytes; nil for anything else.
private func hexBytes(_ text: String) -> [UInt8]? {
  let digits = Array(text.utf8)
  guard digits.count % 2 == 0 else { return nil }
  var bytes: [UInt8] = []
  for i in stride(from: 0, to: digits.count, by: 2) {
    guard let high = nibble(digits[i]), let low = nibble(digits[i + 1]) else { return nil }
    bytes.append(high << 4 | low)
  }
  return bytes
}

private func nibble(_ digit: UInt8) -> UInt8? {
  switch digit {
  case 48...57: return digit - 48
  case 97...102: return digit - 87
  default: return nil
  }
}

// A zero-argument private getter, called only after the object says it answers it.
private func call(_ object: NSObject, _ name: String) throws -> NSObject {
  let sel = selector(name)
  guard object.responds(to: sel), let value = object.perform(sel)?.takeUnretainedValue() as? NSObject else {
    throw Missing(name: name)
  }
  return value
}

// A private property read through KVC; KVC on a key the object lacks raises an exception Swift cannot catch.
private func property(_ object: NSObject, _ name: String) -> Any? {
  object.responds(to: selector(name)) ? object.value(forKey: name) : nil
}

final class Runner: XCTestCase {
  private var lastWork = Date()
  // This start's secret; set before the listener opens, read by every connection.
  private var key: SymmetricKey?
  // One /tree at a time, so the snapshot limit counts only this read's snapshot, not the ones queued before it on main.
  private let snapshots = DispatchSemaphore(value: 1)

  @MainActor
  func testServe() throws {
    // From the .xctestrun copy karagoz started this test with; never logged (K42).
    guard let secret = ProcessInfo.processInfo.environment["KARAGOZ_TOKEN"], let bytes = hexBytes(secret),
      bytes.count == 32
    else { throw Failure("KARAGOZ_TOKEN is missing or malformed") }
    key = SymmetricKey(data: bytes)
    let (listener, accepts) = try open()
    NSLog("karagoz runner listening on 127.0.0.1:%d", Int(port))
    // A timer keeps a source on the main run loop, so each run(mode:before:) waits instead of returning at once.
    let tick = Timer(timeInterval: 1, repeats: true) { _ in }
    RunLoop.current.add(tick, forMode: .default)
    while Date().timeIntervalSince(lastWork) < idleSeconds {
      _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 1))
    }
    tick.invalidate()
    accepts.cancel()
    close(listener)
  }

  // Outside the main actor: connections are read and answered on background queues; only snapshots use main.
  private func open() throws -> (Int32, DispatchSourceRead) {
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    guard listener >= 0 else { throw Failure(String(cString: strerror(errno))) }
    var yes: Int32 = 1
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    // Loopback only: usbmux delivers the host's connection there, and nothing on the phone's Wi-Fi can reach it (K41).
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0, listen(listener, 16) == 0 else {
      let reason = String(cString: strerror(errno))
      close(listener)
      throw Failure("cannot listen on 127.0.0.1:\(port): \(reason)")
    }
    let accepts = DispatchSource.makeReadSource(fileDescriptor: listener, queue: DispatchQueue(label: "karagoz.accept"))
    accepts.setEventHandler { [unowned self] in
      let connection = accept(listener, nil, nil)
      if connection >= 0 { DispatchQueue.global().async { self.serve(connection) } }
    }
    accepts.resume()
    return (listener, accepts)
  }

  // One HTTP/1.0 request per connection; nothing is routed before its MAC checks out (K42).
  private func serve(_ connection: Int32) {
    defer { close(connection) }
    var off: Int32 = 1
    setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &off, socklen_t(MemoryLayout<Int32>.size))
    var wait = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
    var request = Data()
    var buffer = [UInt8](repeating: 0, count: 16384)
    func more() -> Bool {
      let count = read(connection, &buffer, buffer.count)
      if count > 0 { request.append(buffer, count: count) }
      return count > 0
    }
    let terminator = Data("\r\n\r\n".utf8)
    var end = request.range(of: terminator)
    while end == nil, request.count < maxRequestBytes, more() { end = request.range(of: terminator) }
    guard let end else { return respond(connection, 400, ["error": "no request head", "kind": "route"], nonce: nil) }
    let lines = String(decoding: request[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
    var fields: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      if let seen = fields[name], seen != value {
        return respond(connection, 400, ["error": "\(name) given twice", "kind": "route"], nonce: nil)
      }
      fields[name] = value
    }
    let parts = (lines.first ?? "").split(separator: " ")
    let length = fields["content-length"] ?? "0"
    guard parts.count >= 2, !length.isEmpty, length.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let count = Int(length),
      end.upperBound + count <= maxRequestBytes
    else { return respond(connection, 400, ["error": "bad request line or Content-Length", "kind": "route"], nonce: nil) }
    while request.count < end.upperBound + count, more() {}
    guard request.count == end.upperBound + count else {
      return respond(connection, 400, ["error": "the body is not Content-Length long", "kind": "route"], nonce: nil)
    }
    let method = String(parts[0])
    let path = String(parts[1])
    let nonce = fields[nonceHeader] ?? ""
    let body = request.subdata(in: end.upperBound..<request.count)
    guard signed("karagoz-req\n\(nonce)\n\(method) \(path)\n", body, fields[macHeader]) else {
      return respond(connection, 401, ["error": "unauthorized", "kind": "auth"], nonce: nil)
    }
    switch (method, path) {
    case ("GET", "/health"):
      respond(connection, 200, ["protocol": protocolVersion], nonce: nonce)
    case ("GET", "/tree"):
      tree(connection, nonce)
    default:
      respond(connection, 404, ["error": "no route \(method) \(path)", "kind": "route"], nonce: nonce)
    }
  }

  // A request's MAC under this start's secret, compared in constant time by CryptoKit.
  private func signed(_ prefix: String, _ body: Data, _ given: String?) -> Bool {
    guard let key, let given, let mac = hexBytes(given), mac.count == 32 else { return false }
    return HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: Data(prefix.utf8) + body, using: key)
  }

  private func tree(_ connection: Int32, _ nonce: String) {
    snapshots.wait()
    defer { snapshots.signal() }
    var answer: (Int, [String: Any]) = (500, [:])
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.main.async {
      answer = MainActor.assumeIsolated { self.snapshot() }
      done.signal()
    }
    if done.wait(timeout: .now() + snapshotSeconds) == .timedOut {
      respond(connection, 500, [
        "error": "the snapshot did not finish within \(Int(snapshotSeconds)) s", "kind": "snapshot",
      ], nonce: nonce)
      exit(1)
    }
    respond(connection, answer.0, answer.1, nonce: nonce)
  }

  @MainActor
  private func snapshot() -> (Int, [String: Any]) {
    lastWork = Date()
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    do {
      // A system alert covers whatever app is in front; the tree is the alert alone, as on the simulator (K34).
      for modal in [springboard.alerts.firstMatch, springboard.sheets.firstMatch] where modal.exists {
        let frame = springboard.frame
        let root: [String: Any] = [
          "type": XCUIElement.ElementType.application.rawValue,
          "label": springboard.label,
          "frame": [frame.origin.x, frame.origin.y, frame.width, frame.height].map(finite),
          "children": [node(try modal.snapshot())],
        ]
        return (200, ["root": root])
      }
      return (200, ["root": node(try front(springboard).snapshot())])
    } catch let missing as Missing {
      return (500, ["error": "XCTest has no \(missing.name)", "kind": "private"])
    } catch {
      return (500, ["error": error.localizedDescription, "kind": "snapshot"])
    }
  }

  // The app in front: XCTest's own list of active applications, minus SpringBoard, the first one running in the
  // foreground; SpringBoard (the Home screen) when none is. No public API names the frontmost app (K41).
  @MainActor
  private func front(_ springboard: XCUIApplication) throws -> XCUIApplication {
    let client = try call(XCUIDevice.shared, "accessibilityInterface")
    let tracker = try call(client, "applicationProcessTracker")
    guard let elements = try call(client, "activeApplications") as? [NSObject] else {
      throw Missing(name: "activeApplications")
    }
    let system = (property(try call(client, "systemApplication"), "processIdentifier") as? NSNumber)?.int32Value
    let track = selector("monitoredApplicationWithProcessIdentifier:")
    guard tracker.responds(to: track) else { throw Missing(name: "monitoredApplicationWithProcessIdentifier:") }
    typealias Track = @convention(c) (AnyObject, Selector, Int32) -> Unmanaged<AnyObject>?
    let monitored = unsafeBitCast(tracker.method(for: track), to: Track.self)
    for element in elements {
      guard let pid = (property(element, "processIdentifier") as? NSNumber)?.int32Value else {
        throw Missing(name: "processIdentifier")
      }
      if pid == system { continue }
      if let app = monitored(tracker, track, pid)?.takeUnretainedValue() as? XCUIApplication,
        app.state == .runningForeground
      {
        return app
      }
    }
    return springboard
  }

  // Raw snapshot data in points; the host maps types to roles and points to pixels (K41).
  private func node(_ snapshot: XCUIElementSnapshot) -> [String: Any] {
    var out: [String: Any] = ["type": snapshot.elementType.rawValue]
    if !snapshot.label.isEmpty { out["label"] = snapshot.label }
    if !snapshot.identifier.isEmpty { out["identifier"] = snapshot.identifier }
    if let value = snapshot.value {
      let text = (value as? NSNumber)?.stringValue ?? (value as? String) ?? String(describing: value)
      if !text.isEmpty { out["value"] = text }
    }
    if let placeholder = snapshot.placeholderValue, !placeholder.isEmpty { out["placeholder"] = placeholder }
    if !snapshot.isEnabled { out["enabled"] = false }
    if snapshot.isSelected { out["selected"] = true }
    if let object = snapshot as AnyObject as? NSObject {
      // The field a software keyboard types into; the public hasFocus is the focus engine's answer (K41).
      if (property(object, "hasKeyboardFocus") as? NSNumber)?.boolValue == true { out["focused"] = true }
      if let traits = (property(object, "traits") as? NSNumber)?.uint64Value, traits & headerTrait != 0 {
        out["heading"] = true
      }
    }
    let frame = snapshot.frame
    out["frame"] = [frame.origin.x, frame.origin.y, frame.width, frame.height].map(finite)
    let children = snapshot.children.map(node)
    if !children.isEmpty { out["children"] = children }
    return out
  }

  // Signed with this start's secret for a request that was; a refusal (nonce nil) goes out unsigned (K42).
  private func respond(_ connection: Int32, _ status: Int, _ body: [String: Any], nonce: String?) {
    let json = (try? JSONSerialization.data(withJSONObject: body)) ?? Data(#"{"error":"unencodable","kind":"snapshot"}"#.utf8)
    let reasons = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found"]
    var head = "HTTP/1.0 \(status) \(reasons[status] ?? "Internal Server Error")\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n"
    if let nonce, let key {
      let mac = HMAC<SHA256>.authenticationCode(for: Data("karagoz-res\n\(nonce)\n\(status)\n".utf8) + json, using: key)
      head += "X-Karagoz-Mac: \(mac.map { String(format: "%02x", $0) }.joined())\r\n"
    }
    let bytes = Data((head + "\r\n").utf8) + json
    bytes.withUnsafeBytes { raw in
      var sent = 0
      while sent < raw.count {
        let count = write(connection, raw.baseAddress! + sent, raw.count - sent)
        if count <= 0 { return }
        sent += count
      }
    }
  }
}

// JSONSerialization refuses NaN and infinity; an element without a frame reports zeros.
private func finite(_ value: CGFloat) -> Double { value.isFinite ? Double(value) : 0 }
