// karagoz's iOS simulator helper: prints the frontmost app's accessibility tree of one booted simulator, or sends it
// one input. The tree flow is idb's FBSimulatorAX (MIT); touches, keys and buttons go to the simulator's own HID daemon
// dtuhidd, as idb does on Xcode 27 (DTUHID, MIT) (K34, K35). Contract with src/drivers/ios/ui-tree.ts and input.ts:
//   ax <developer dir> <udid>
//     exit 0: one JSON object, {"screen":{"width","height","scale"},"root":<node>}, frames in points
//   ax <developer dir> <udid> tap <rx> <ry> <holdMs> | swipe <rx1> <ry1> <rx2> <ry2> <durationMs> | key <usage>
//     | button <page> <usage>
//     ratios of the unrotated portrait panel; exit 0 and no output once the input is sent
//   exit 2: unavailable on this Xcode (a private class, selector or symbol is missing); 3: this screen could not be
//   read; 4: no input service in this simulator (Xcode 26 and older); 5: the input service did not answer; 7: the
//   input failed. Every non-zero exit writes one line, "ax: <reason>", to stderr.
import AppKit
import Foundation
import XPC

@objc protocol AXPTranslatorP: NSObjectProtocol {
  var bridgeTokenDelegate: AnyObject? { get set }
  var supportsDelegateTokens: Bool { get set }
  func frontmostApplication(withDisplayId displayId: UInt32, bridgeDelegateToken token: String) -> AnyObject?
  func macPlatformElement(fromTranslation translation: AnyObject) -> AnyObject?
}
@objc protocol TranslationP: NSObjectProtocol {
  var bridgeDelegateToken: String? { get set }
}
@objc protocol SimDeviceP: NSObjectProtocol {
  @objc(UDID) var udid: NSUUID { get }
  func sendAccessibilityRequestAsync(
    _ req: AnyObject, completionQueue: DispatchQueue, completionHandler: @escaping (AnyObject?) -> Void)
  func lookup(_ name: String, error: AutoreleasingUnsafeMutablePointer<NSError?>) -> mach_port_t
}
@objc protocol ServiceContextClassP: NSObjectProtocol {
  static func sharedServiceContext(forDeveloperDir dir: String, error: AutoreleasingUnsafeMutablePointer<NSError?>)
    -> AnyObject?
}
@objc protocol ServiceContextP: NSObjectProtocol {
  func defaultDeviceSetWithError(_ error: AutoreleasingUnsafeMutablePointer<NSError?>) -> AnyObject?
}
@objc protocol DeviceSetP: NSObjectProtocol {
  var devices: [AnyObject] { get }
}

let unavailable: Int32 = 2
let unreadable: Int32 = 3
let noService: Int32 = 4
let notAnswering: Int32 = 5
let failed: Int32 = 7

func quit(_ code: Int32, _ message: String) -> Never {
  fflush(stdout)
  FileHandle.standardError.write(Data(("ax: " + message + "\n").utf8))
  exit(code)
}

// An unchecked private selector raises an NSException and aborts the process; a missing one exits 2 instead.
func need(_ object: AnyObject, _ selectors: String...) {
  for name in selectors where !object.responds(to: NSSelectorFromString(name)) {
    quit(unavailable, "no \(name) on \(type(of: object))")
  }
}

func pause(_ ms: Double) { if ms > 0 { Thread.sleep(forTimeInterval: ms / 1000) } }

func number(_ text: String) -> Double {
  guard let value = Double(text), value.isFinite else { quit(unavailable, "not a number: \(text)") }
  return value
}

typealias EndpointFromPort = @convention(c) (mach_port_t, UInt64, UInt64) -> Unmanaged<AnyObject>?
typealias ConnectionFromEndpoint = @convention(c) (xpc_object_t) -> Unmanaged<AnyObject>?
typealias EnableSim2Host = @convention(c) (xpc_connection_t) -> Void

// libxpc's simulator functions have no header; a missing one exits 2 like a missing selector.
func symbol<T>(_ name: String, _ type: T.Type) -> T {
  guard let pointer = dlsym(dlopen(nil, RTLD_NOW), name) else { quit(unavailable, "no \(name)") }
  return unsafeBitCast(pointer, to: type)
}

let hidService = "com.apple.coredevice.feature.remote.hid.digitizer"

// One touch, key or button through DTUHID. Sent once: only the service's readiness is waited for (K11, K35).
func hid(_ device: SimDeviceP, _ input: [String]) -> Never {
  let shapes = ["tap": 3, "swipe": 5, "key": 1, "button": 2]
  guard let mode = input.first, shapes[mode] == input.count - 1 else {
    quit(unavailable, "unknown input: \(input.joined(separator: " "))")
  }
  let values = input.dropFirst().map(number)
  let endpointFromPort = symbol("xpc_endpoint_create_mach_port_4sim", EndpointFromPort.self)
  let connectionFromEndpoint = symbol("xpc_connection_create_from_endpoint", ConnectionFromEndpoint.self)
  let enableSim2Host = symbol("xpc_connection_enable_sim2host_4sim", EnableSim2Host.self)
  var error: NSError?
  let port = device.lookup(hidService, error: &error)
  guard port != MACH_PORT_NULL else {
    quit(noService, "no dtuhidd in this simulator (\(error?.localizedDescription ?? "lookup failed"))")
  }
  guard let endpoint = endpointFromPort(port, 0, 0)?.takeRetainedValue() as? xpc_object_t,
    let connection = connectionFromEndpoint(endpoint)?.takeRetainedValue() as? xpc_connection_t
  else { quit(failed, "cannot connect to dtuhidd") }
  enableSim2Host(connection)
  let queue = DispatchQueue(label: "ax.hid")
  xpc_connection_set_target_queue(connection, queue)
  // Connection errors also reach the barrier's reply, which reports them.
  xpc_connection_set_event_handler(connection) { _ in }
  xpc_connection_activate(connection)

  func message(_ type: String, barrier: Bool = false, _ fill: (xpc_object_t) -> Void) -> xpc_object_t {
    let message = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_string(message, "messageType", type)
    xpc_dictionary_set_bool(message, "isBarrier", barrier)
    xpc_dictionary_set_string(message, "featureIdentifier", hidService)
    let payload = xpc_dictionary_create(nil, nil, 0)
    fill(payload)
    xpc_dictionary_set_value(message, "payload", payload)
    return message
  }
  // A usage-0 key with a reply. A fresh connection's events are dropped until dtuhidd activates its services for
  // the new peer, and the reply says it did: 0/3 taps landed without it, 3/3 with it (K35).
  func barrier(_ seconds: Double) -> String? {
    let replied = DispatchSemaphore(value: 0)
    var failure: String?
    let probe = message("IndigoKeyboardButtonEvent", barrier: true) {
      xpc_dictionary_set_uint64($0, "usageCode", 0)
      xpc_dictionary_set_uint64($0, "state", 2)
    }
    xpc_connection_send_message_with_reply(connection, probe, queue) { reply in
      if xpc_get_type(reply) == XPC_TYPE_ERROR {
        failure = xpc_dictionary_get_string(reply, XPC_ERROR_KEY_DESCRIPTION).map { String(cString: $0) } ?? "error"
      }
      replied.signal()
    }
    if replied.wait(timeout: .now() + seconds) == .timedOut { return "no reply within \(Int(seconds)) s" }
    return failure
  }
  // Each event leaves before the next one is built, as the prototype measured.
  func send(_ event: xpc_object_t, until deadline: DispatchTime = .distantFuture) {
    xpc_connection_send_message(connection, event)
    let sent = DispatchSemaphore(value: 0)
    xpc_connection_send_barrier(connection) { sent.signal() }
    _ = sent.wait(timeout: deadline)
  }
  func digitizer(_ x: Double, _ y: Double, _ phase: UInt64) -> xpc_object_t {
    message("IndigoDigitizerEvent") {
      let point = xpc_dictionary_create(nil, nil, 0)
      xpc_dictionary_set_double(point, "x", x)
      xpc_dictionary_set_double(point, "y", y)
      xpc_dictionary_set_value($0, "pointOne", point)
      xpc_dictionary_set_uint64($0, "eventType", phase)
      xpc_dictionary_set_uint64($0, "edge", 0)
      xpc_dictionary_set_uint64($0, "target", 0)
    }
  }

  // Node's timeout and an MCP cancel end the helper with SIGTERM: a touch still down is lifted, or the next gesture
  // lands on a held finger. Node waits for the process and closes its pipes, so the handler ends fast and prints nothing.
  let lock = NSLock()
  var down: (x: Double, y: Double)?
  var ending = false
  signal(SIGPIPE, SIG_IGN)
  signal(SIGTERM, SIG_IGN)
  let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: DispatchQueue(label: "ax.term"))
  terminate.setEventHandler {
    let locked = lock.lock(before: Date(timeIntervalSinceNow: 1))
    ending = true
    if let point = down { send(digitizer(point.x, point.y, 2), until: .now() + 1) }
    if locked { lock.unlock() }
    _exit(143)
  }
  terminate.activate()
  func touch(_ x: Double, _ y: Double, _ phase: UInt64) {
    lock.lock()
    defer { lock.unlock() }
    if ending { return }
    send(digitizer(x, y, phase))
    down = phase == 2 ? nil : (x, y)
  }
  func press(_ type: String, _ fill: @escaping (xpc_object_t) -> Void) {
    for state: UInt64 in [1, 2] {
      send(message(type) {
        fill($0)
        xpc_dictionary_set_uint64($0, "state", state)
      })
    }
  }

  if let reason = barrier(4) { quit(notAnswering, "dtuhidd did not answer: \(reason)") }
  switch mode {
  case "tap":
    touch(values[0], values[1], 0)
    pause(values[2])
    touch(values[0], values[1], 2)
  case "swipe":
    let (x1, y1, x2, y2, duration) = (values[0], values[1], values[2], values[3], values[4])
    let steps = max(1, Int(duration / 16))
    touch(x1, y1, 0)
    for step in 1...steps {
      pause(duration / Double(steps))
      let f = Double(step) / Double(steps)
      touch(x1 + (x2 - x1) * f, y1 + (y2 - y1) * f, 1)
    }
    touch(x2, y2, 1)
    touch(x2, y2, 2)
  case "key":
    press("IndigoKeyboardButtonEvent") { xpc_dictionary_set_uint64($0, "usageCode", UInt64(values[0])) }
  default:
    press("IndigoButtonEvent") {
      xpc_dictionary_set_uint64($0, "usagePage", UInt64(values[0]))
      xpc_dictionary_set_uint64($0, "usageCode", UInt64(values[1]))
    }
  }
  // ponytail: a fixed wait, measured on one Mac: exiting at once landed 0/3 taps, 80 ms 5/5, and a final barrier's
  // reply in its place 0/5 (K35). If taps drop on a slower Mac, this number goes up.
  pause(80)
  xpc_connection_cancel(connection)
  exit(0)
}

let args = CommandLine.arguments
guard args.count >= 3 else { quit(unavailable, "usage: ax <developer dir> <udid> [<input>]") }
guard dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW) != nil else {
  quit(unavailable, String(cString: dlerror()))
}

guard let contextClass = NSClassFromString("SimServiceContext") else { quit(unavailable, "no SimServiceContext") }
need(contextClass, "sharedServiceContextForDeveloperDir:error:")
var error: NSError?
guard
  let context = unsafeBitCast(contextClass, to: ServiceContextClassP.Type.self).sharedServiceContext(
    forDeveloperDir: args[1], error: &error)
else { quit(unavailable, "service context: \(error?.localizedDescription ?? "nil")") }
need(context, "defaultDeviceSetWithError:")
guard let set = unsafeBitCast(context, to: ServiceContextP.self).defaultDeviceSetWithError(&error) else {
  quit(unavailable, "device set: \(error?.localizedDescription ?? "nil")")
}
need(set, "devices")
let candidates = unsafeBitCast(set, to: DeviceSetP.self).devices
for candidate in candidates { need(candidate, "UDID") }
guard
  let found = candidates.first(where: { unsafeBitCast($0, to: SimDeviceP.self).udid.uuidString == args[2] }),
  let object = found as? NSObject
else { quit(unavailable, "no device \(args[2])") }
if args.count > 3 {
  need(object, "lookup:error:")
  hid(unsafeBitCast(object, to: SimDeviceP.self), Array(args[3...]))
}
guard
  dlopen(
    "/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation",
    RTLD_NOW) != nil
else { quit(unavailable, String(cString: dlerror())) }
need(object, "sendAccessibilityRequestAsync:completionQueue:completionHandler:", "deviceType")
let device = unsafeBitCast(object, to: SimDeviceP.self)

// KVC boxes the getters' C types (CGSize, float) whatever their exact declaration.
guard let deviceType = object.value(forKey: "deviceType") as? NSObject else { quit(unavailable, "no device type") }
need(deviceType, "mainScreenSize", "mainScreenScale")
guard let size = (deviceType.value(forKey: "mainScreenSize") as? NSValue)?.sizeValue,
  let scale = (deviceType.value(forKey: "mainScreenScale") as? NSNumber)?.doubleValue
else { quit(unavailable, "no main screen size or scale") }

final class Bridge: NSObject {
  let device: SimDeviceP
  let queue = DispatchQueue(label: "ax.callback")
  init(device: SimDeviceP) { self.device = device }

  @objc(accessibilityTranslationDelegateBridgeCallbackWithToken:)
  func callback(token: String) -> @convention(block) (AnyObject?) -> AnyObject? {
    return { request in
      guard let request else { return nil }
      let group = DispatchGroup()
      group.enter()
      var response: AnyObject?
      self.device.sendAccessibilityRequestAsync(request, completionQueue: self.queue) {
        response = $0
        group.leave()
      }
      // idb's per-request timeout.
      if group.wait(timeout: .now() + 5) == .timedOut { quit(unreadable, "accessibility request timed out after 5 s") }
      return response
    }
  }
  @objc(accessibilityTranslationConvertPlatformFrameToSystem:withToken:)
  func convert(_ rect: CGRect, token: String) -> CGRect { rect }
  @objc(accessibilityTranslationRootParentWithToken:)
  func rootParent(token: String) -> AnyObject? { nil }
}

guard let translatorClass = NSClassFromString("AXPTranslator") as? NSObject.Type else {
  quit(unavailable, "no AXPTranslator")
}
need(translatorClass, "sharedInstance")
guard let shared = translatorClass.perform(NSSelectorFromString("sharedInstance"))?.takeUnretainedValue() else {
  quit(unavailable, "no translator instance")
}
need(
  shared, "setBridgeTokenDelegate:", "setSupportsDelegateTokens:",
  "frontmostApplicationWithDisplayId:bridgeDelegateToken:", "macPlatformElementFromTranslation:")
let translator = unsafeBitCast(shared, to: AXPTranslatorP.self)
let bridge = Bridge(device: device)
translator.bridgeTokenDelegate = bridge
translator.supportsDelegateTokens = true
let token = UUID().uuidString
guard let translation = translator.frontmostApplication(withDisplayId: 0, bridgeDelegateToken: token) else {
  quit(unreadable, "no frontmost application")
}
need(translation, "setBridgeDelegateToken:")
unsafeBitCast(translation, to: TranslationP.self).bridgeDelegateToken = token
guard let root = translator.macPlatformElement(fromTranslation: translation) as? NSAccessibilityElement else {
  quit(unreadable, "no platform element")
}

// UIAccessibilityTraitSelected. The traits number can exceed 2^53, so only this bit leaves the helper.
let selectedTrait: UInt64 = 1 << 3

func selected(_ element: NSObject) -> Bool {
  let selector = NSSelectorFromString("accessibilityAttributeValue:")
  guard element.responds(to: selector),
    let traits = (element.perform(selector, with: "AXTraits")?.takeUnretainedValue() as? NSNumber)?.uint64Value
  else { return false }
  return traits & selectedTrait != 0
}

func walk(_ element: NSAccessibilityElement) -> [String: Any] {
  var node: [String: Any] = ["role": element.accessibilityRole()?.rawValue ?? ""]
  if let subrole = element.accessibilitySubrole()?.rawValue, !subrole.isEmpty { node["subrole"] = subrole }
  if let label = element.accessibilityLabel(), !label.isEmpty { node["label"] = label }
  if let id = element.accessibilityIdentifier(), !id.isEmpty { node["identifier"] = id }
  if let value = element.accessibilityValue() {
    let text = "\(value)"
    if !text.isEmpty { node["value"] = text }
  }
  if selected(element) { node["selected"] = true }
  if element.isAccessibilityFocused() { node["focused"] = true }
  if !element.isAccessibilityEnabled() { node["enabled"] = false }
  let f = element.accessibilityFrame()
  node["frame"] = [f.origin.x, f.origin.y, f.size.width, f.size.height]
  let children = (element.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }.map(walk)
  if !children.isEmpty { node["children"] = children }
  return node
}

let output: [String: Any] = [
  "screen": ["width": size.width, "height": size.height, "scale": scale],
  "root": walk(root),
]
// A NaN or infinite frame would raise an NSException inside JSONSerialization.
guard JSONSerialization.isValidJSONObject(output),
  let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
else { quit(unreadable, "the tree has a value JSON cannot hold") }
FileHandle.standardOutput.write(data)
fflush(stdout)
exit(0)
