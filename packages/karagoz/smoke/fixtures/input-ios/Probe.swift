// The app the iOS smokes drive on a simulator. Every input leaves a mark ui-tree shows: a counter in a label, the
// field's echo, the selected text, the first visible row, the last URL it was opened with. Each launch argument goes to
// the unified log, where smoke 3.6 reads it back.
import SwiftUI
import os

struct ContentView: View {
  @State private var name = ""
  @State private var taps = 0
  @State private var longs = 0
  @State private var presses = 0
  @State private var doubles = 0
  @State private var words = "hello world"
  @State private var selection: TextSelection?
  @State private var opened = ""

  // A word a double tap selected; empty for a caret or several ranges.
  private var selected: String {
    guard case .selection(let range) = selection?.indices else { return "" }
    return String(words[range])
  }

  var body: some View {
    NavigationStack {
      List {
        Section("Form") {
          TextField("Name", text: $name).accessibilityIdentifier("name-field").autocorrectionDisabled()
          Text("echo:\(name)").accessibilityIdentifier("echo")
          Button("Tap me \(taps)") { taps += 1 }.accessibilityIdentifier("tap-button")
          Text("Long \(longs)").accessibilityIdentifier("long-target")
            .frame(maxWidth: .infinity, minHeight: 60).contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0.5) { longs += 1 }
          Text("Double \(doubles)").accessibilityIdentifier("double-target")
            .frame(maxWidth: .infinity, minHeight: 60).contentShape(Rectangle())
            .onTapGesture(count: 2) { doubles += 1 }
          // Above its field: the keyboard covers what is below it.
          Text("selected:\(selected)").accessibilityIdentifier("selection")
          TextField("Words", text: $words, selection: $selection).accessibilityIdentifier("word-field")
            .autocorrectionDisabled()
          Button("Press") { presses += 1 }.accessibilityIdentifier("press-button")
          Text("pressed \(presses)").accessibilityIdentifier("press-count")
          // Only after open-url, so the rows every other smoke reads stay where they are.
          if !opened.isEmpty { Text("opened:\(opened)").accessibilityIdentifier("opened-url") }
        }
        Section("Rows") {
          ForEach(1...40, id: \.self) { Text("Row \($0)") }
        }
      }
      .navigationTitle("Probe")
    }
    .onOpenURL { opened = $0.absoluteString }
  }
}

@main
struct ProbeApp: App {
  init() {
    let log = Logger(subsystem: "dev.karagoz.probe", category: "smoke")
    for arg in CommandLine.arguments.dropFirst() { log.notice("\(arg, privacy: .public)") }
  }

  var body: some Scene { WindowGroup { ContentView() } }
}
