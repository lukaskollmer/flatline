import Shapes
// Used: the operator is declared in ShapeExtras.
import ShapeExtras

func combinedSides() -> Int {
    (makeShape(sides: 1) <+> makeShape(sides: 2)).sides
}
