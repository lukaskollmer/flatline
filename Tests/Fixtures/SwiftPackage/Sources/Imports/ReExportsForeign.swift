// Not reported: ShapeKit re-exports Foundation, whose uses can't be seen.
import ShapeKit

func reExportedForeign() -> Bool {
    Date.distantPast < Date.distantFuture
}
