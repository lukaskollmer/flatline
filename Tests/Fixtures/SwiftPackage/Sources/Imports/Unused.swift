// Imports of modules outside the project aren't analyzed.
import Foundation
import Shapes // expect: unusedImport
import ShapeExtras // expect: unusedImport
// periphery:ignore
import ShapeKit

#if false
import ShapeKit
#endif

func unusedImports() -> Int {
    1
}
