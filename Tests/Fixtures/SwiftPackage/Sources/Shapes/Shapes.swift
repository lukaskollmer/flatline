public struct Shape {
    public let sides: Int
}

/// Gets a conformance from ShapeExtras.
public struct Color {
    public let name: String
}

/// Gets a default implementation from ShapeExtras.
public protocol Drawable {
    func draw() -> String
}

public func makeShape(sides: Int) -> Shape {
    Shape(sides: sides)
}

public func makeColor() -> Color {
    Color(name: "red")
}
