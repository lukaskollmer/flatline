import Shapes
// Used: Color is CustomStringConvertible through an extension in ShapeExtras.
import ShapeExtras

func conformance() -> String {
    let color: Color = makeColor()
    return describe(color)
}

private func describe(_ value: some CustomStringConvertible) -> String {
    value.description
}
