import Shapes // expect: unusedImport
// Not reported: Leaked.swift uses ShapeExtras without importing it, which
// works only because this file imports it.
import ShapeExtras

func unused() -> Int {
    0
}
