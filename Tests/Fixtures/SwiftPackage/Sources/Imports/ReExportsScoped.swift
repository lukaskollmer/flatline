// Not reported: URL comes from ShapeKit's re-export of Foundation, which
// importing a single declaration of Foundation doesn't replace.
import ShapeKit
import struct Foundation.Date

func scopedForeign() -> Bool {
    URL(string: "https://example.org") != nil && Date.distantPast < Date.distantFuture
}
