// karagoz's iOS simulator tree reader: prints the frontmost app's accessibility tree of one booted simulator.
// The CoreSimulator and AccessibilityPlatformTranslation flow is idb's FBSimulatorAX (MIT). Read-only: no input, no
// state change. Contract with src/drivers/ios/ui-tree.ts:
//   ax <developer dir> <udid>
//   exit 0: one JSON object, {"screen":{"width","height","scale"},"root":<node>}, frames in points
//   exit 2: unavailable on this Xcode (a private class or selector is missing); exit 3: this screen could not be read
//   exit 2 or 3 writes one line, "ax: <reason>", to stderr
import AppKit
import Foundation

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

let args = CommandLine.arguments
guard args.count == 3 else { quit(unavailable, "usage: ax <developer dir> <udid>") }
for path in [
  "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator",
  "/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation",
] where dlopen(path, RTLD_NOW) == nil {
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
