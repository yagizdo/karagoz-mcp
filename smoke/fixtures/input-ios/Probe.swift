// The app smoke 3.4 drives on a simulator. Every input leaves a mark ui-tree shows: a counter in a label, the field's
// echo, the first visible row.
import SwiftUI

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
  var body: some Scene { WindowGroup { ContentView() } }
}
