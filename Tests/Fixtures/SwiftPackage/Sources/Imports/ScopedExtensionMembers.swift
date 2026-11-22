import Shapes
// Used: any import of ShapeExtras, even of one declaration, makes its
// extension members visible.
import struct ShapeExtras.Ruler

func scopedExtensionMember() -> Bool {
    makeShape(sides: 3).isTriangle
}
