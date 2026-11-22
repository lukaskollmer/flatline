// ShapeKit also re-exports Foundation; importing it here makes ShapeKit's uses visible.
import Foundation
// Used: ShapeKit re-exports Shapes.
import ShapeKit

func reExported() -> Int {
    makeShape(sides: 4).sides
}
