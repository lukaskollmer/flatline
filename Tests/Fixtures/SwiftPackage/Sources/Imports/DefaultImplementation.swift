import Shapes
// Used: Pen gets draw() from an extension in ShapeExtras.
import ShapeExtras

struct Pen: Drawable {}

func defaultImplementation() -> String {
    render(Pen())
}

private func render(_ drawable: some Drawable) -> String {
    drawable.draw()
}
