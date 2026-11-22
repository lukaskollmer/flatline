// Not reported: URL comes from ShapeKit's re-export of Foundation. DateKit
// re-exports only Foundation.Date, which doesn't make all of Foundation visible.
import DateKit
import ShapeKit

func reExportedDeclaration() -> Bool {
    marker() && URL(string: "https://example.org") != nil
}
