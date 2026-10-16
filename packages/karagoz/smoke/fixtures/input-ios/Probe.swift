// The app the iOS smokes drive on a simulator. Every input leaves a mark ui-tree shows: a counter in a label, the
// field's echo, the first visible row. Each launch argument goes to the unified log, where smoke 3.6 reads it back.
import SwiftUI
import os

struct ContentView: View {
  @State private var name = ""
  @State private var taps = 0
  @State private var longs = 0
  @State private var presses = 0

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
          Button("Press") { presses += 1 }.accessibilityIdentifier("press-button")
          Text("pressed \(presses)").accessibilityIdentifier("press-count")
        }
        Section("Rows") {
          ForEach(1...40, id: \.self) { Text("Row \($0)") }
        }
      }
      .navigationTitle("Probe")
    }
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
