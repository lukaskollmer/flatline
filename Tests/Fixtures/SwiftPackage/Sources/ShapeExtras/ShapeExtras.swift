import Shapes

extension Color: CustomStringConvertible {
    public var description: String {
        name
    }
}

extension Drawable {
    public func draw() -> String {
        "drawn"
    }
}

extension Shape {
    public var isTriangle: Bool {
        sides == 3
    }
}

infix operator <+>: AdditionPrecedence

public func <+> (lhs: Shape, rhs: Shape) -> Shape {
    makeShape(sides: lhs.sides + rhs.sides)
}

extension DefaultStringInterpolation {
    public mutating func appendInterpolation(sidesOf shape: Shape) {
        appendLiteral("\(shape.sides) sides")
    }
}

/// Only imported on its own, with `import struct ShapeExtras.Ruler`.
public struct Ruler {}
