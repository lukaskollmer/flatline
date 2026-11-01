import Foundation
import Observation
import SwiftUI

struct ContentView: View {
    @State private var model = Model()

    var body: some View {
        Text(model.title).onTapGesture(perform: tapped)
    }

    func tapped() {
        model.title = "tapped"
    }
}

#Preview {
    ContentView()
}

@Observable final class Model {
    var title = "Hello"
    var unusedObservable = 0 // expect: unused
}

struct UnusedView: View { // expect: unused
    var body: some View { Text("unused") }
}

/// `@State` is a macro in recent SDKs; its expansion must not keep the view alive.
struct UnusedStatefulView: View { // expect: unused
    @State private var count = 0
    var body: some View { Text("\(count)") }
}

struct LegacyPreview: PreviewProvider {
    static var previews: some View { PreviewedView() }
}

struct PreviewedView: View {
    var body: some View { Text("previewed") }
}

@objc final class ObjCTarget: NSObject {
    @objc func action(_ sender: Any) {}
    func swiftOnly() {} // expect: unused
}

final class PlainObject: NSObject {} // expect: unused
