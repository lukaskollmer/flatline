import struct Shapes.Shape
import func Shapes.makeColor // expect: unusedImport
import func Shapes.makeShape

func scopedImports() -> Int {
    let shape: Shape = makeShape(sides: 5)
    return shape.sides
}
